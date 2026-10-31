package com.nexus.runtime

import android.content.Context
import android.os.Build
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

/**
 * Executes commands inside the embedded Linux environment using proot.
 *
 * Note: command strings are treated as trusted (Studio power tool).
 * Full allowlisting is a later phase.
 */
class ProotExecutor(
    private val context: Context,
    private val bootstrapManager: BootstrapManager
) {

    companion object {
        private const val DEFAULT_TIMEOUT_SEC = 60L
        private const val MAX_OUTPUT_BYTES = 2 * 1024 * 1024 // 2 MB
    }

    data class CommandResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean = false
    )

    /**
     * Ensure workingDir stays under runtime root (guest path for proot -w).
     * Accepts absolute guest paths under prefix, or relative under /home.
     */
    private fun safeWorkingDir(raw: String?, prefix: File, runtimeRoot: File): String {
        // proot -w expects a path inside the guest rootfs (prefix)
        val defaultGuest = "/home"
        if (raw.isNullOrBlank()) return defaultGuest

        // Only allow simple relative or absolute-within-prefix style paths
        // Reject obvious host escapes
        if (raw.contains("..")) {
            RuntimeLogger.w("workingDir rejected (contains ..): $raw")
            return defaultGuest
        }
        // Guest path: must start with / and not point at host-only locations
        val guest = if (raw.startsWith("/")) raw else "/home/$raw"
        val blocked = listOf("/data", "/system", "/vendor", "/proc", "/dev", "/sys", "/acct", "/mnt", "/storage")
        for (b in blocked) {
            if (guest == b || guest.startsWith("$b/")) {
                RuntimeLogger.w("workingDir rejected (blocked prefix): $raw")
                return defaultGuest
            }
        }
        return guest
    }

    fun run(
        command: String,
        workingDir: String? = null,
        timeoutSec: Long = DEFAULT_TIMEOUT_SEC
    ): CommandResult {
        if (!bootstrapManager.isReady) {
            return CommandResult(
                exitCode = -1,
                stdout = "",
                stderr = "Runtime not ready. Call initialize() first.",
                timedOut = false
            )
        }

        val prefix = bootstrapManager.prefixDir.canonicalFile
        val runtimeRoot = File(bootstrapManager.getRuntimeRootPath()).canonicalFile
        val nativeLibDir = context.applicationInfo.nativeLibraryDir
        val guestWorkDir = safeWorkingDir(workingDir, prefix, runtimeRoot)

        val prootCandidates = listOf(
            File(nativeLibDir, "libproot.so"),
            File(nativeLibDir, "proot"),
            File(prefix, "bin/proot"),
            File(prefix, "usr/bin/proot")
        )
        val actualProotFile = prootCandidates.firstOrNull { it.exists() && it.canExecute() }
        if (actualProotFile == null) {
            return CommandResult(
                exitCode = -1,
                stdout = "",
                stderr = "proot binary not found or not executable in nativeLibraryDir / prefix",
                timedOut = false
            )
        }
        val actualProot = actualProotFile.absolutePath
        val loaderPath = File(nativeLibDir, "libproot-loader.so").absolutePath

        val env = mutableMapOf<String, String>()
        env["PROOT_LOADER"] = loaderPath
        env["PROOT_TMP_DIR"] = File(runtimeRoot, "tmp").absolutePath
        env["PREFIX"] = prefix.absolutePath
        env["HOME"] = File(runtimeRoot, "home").absolutePath
        env["TMPDIR"] = File(runtimeRoot, "tmp").absolutePath
        env["PATH"] = "${prefix.absolutePath}/bin:${prefix.absolutePath}/usr/bin"
        env["LD_LIBRARY_PATH"] = "${prefix.absolutePath}/lib:${nativeLibDir}"
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"

        val prootArgs = mutableListOf<String>().apply {
            add(actualProot)
            add("-0")
            add("-r")
            add(prefix.absolutePath)
            add("-b")
            add("/dev")
            add("-b")
            add("/proc")
            add("-b")
            add("/sys")
            add("-b")
            add("${runtimeRoot.absolutePath}/tmp:/tmp")
            add("-b")
            add("${runtimeRoot.absolutePath}/home:/home")
            add("-w")
            add(guestWorkDir)
            add("/bin/sh")
            add("-c")
            add(command)
        }

        RuntimeLogger.d("Executing proot (cmd length=${command.length}, cwd=$guestWorkDir)")

        return try {
            val processBuilder = ProcessBuilder(prootArgs)
            processBuilder.environment().clear()
            processBuilder.environment().putAll(env)
            processBuilder.redirectErrorStream(false)

            val process = processBuilder.start()

            val stdout = StringBuilder()
            val stderr = StringBuilder()

            val stdoutThread = Thread {
                readCapped(process.inputStream, stdout)
            }.apply { name = "nexus-proot-stdout"; isDaemon = true }

            val stderrThread = Thread {
                readCapped(process.errorStream, stderr)
            }.apply { name = "nexus-proot-stderr"; isDaemon = true }

            stdoutThread.start()
            stderrThread.start()

            val finished = process.waitFor(timeoutSec, TimeUnit.SECONDS)

            if (!finished) {
                killProcessTree(process)
                stdoutThread.join(800)
                stderrThread.join(800)
                return CommandResult(
                    exitCode = -1,
                    stdout = stdout.toString().trim(),
                    stderr = (stderr.toString().trim() + "\n[Timeout after ${timeoutSec}s]").trim(),
                    timedOut = true
                )
            }

            stdoutThread.join(2000)
            stderrThread.join(2000)

            CommandResult(
                exitCode = process.exitValue(),
                stdout = stdout.toString().trim(),
                stderr = stderr.toString().trim(),
                timedOut = false
            )
        } catch (e: Exception) {
            RuntimeLogger.e("Execution failed", e)
            CommandResult(
                exitCode = -1,
                stdout = "",
                stderr = "Execution error: ${e.message}",
                timedOut = false
            )
        }
    }

    /** Cap by UTF-8 byte size, not UTF-16 char count. */
    private fun readCapped(stream: java.io.InputStream, out: StringBuilder) {
        try {
            stream.bufferedReader(Charsets.UTF_8).use { reader ->
                val buf = CharArray(8192)
                var totalBytes = 0
                while (true) {
                    val n = reader.read(buf)
                    if (n == -1) break
                    val chunk = String(buf, 0, n)
                    val bytes = chunk.toByteArray(Charsets.UTF_8).size
                    if (totalBytes + bytes > MAX_OUTPUT_BYTES) {
                        out.append("\n[output truncated at $MAX_OUTPUT_BYTES bytes]")
                        return
                    }
                    totalBytes += bytes
                    out.append(chunk)
                }
            }
        } catch (_: Exception) {
            // process closed / stream ended
        }
    }

    /**
     * Best-effort kill of process + children.
     * Uses ProcessHandle on API 26+, and a process-group kill fallback.
     */
    private fun killProcessTree(process: Process) {
        // Primary: ProcessHandle descendants (API 26+)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                process.toHandle().descendants().forEach { handle ->
                    try { handle.destroyForcibly() } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}

        // Fallback: try killing process group via pid (helps on older API / proot children)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val pid = process.toHandle().pid()
                // Negative PID = process group (when started as session leader; best-effort)
                Runtime.getRuntime().exec(arrayOf("sh", "-c", "kill -TERM -$pid 2>/dev/null; sleep 0.3; kill -KILL -$pid 2>/dev/null; kill -KILL $pid 2>/dev/null"))
            }
        } catch (_: Exception) {}

        try {
            process.destroyForcibly()
        } catch (_: Exception) {}
    }
}
