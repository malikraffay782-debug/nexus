package com.nexus.runtime

import android.content.Context
import android.os.Build
import java.io.File
import java.nio.file.Paths
import java.util.concurrent.TimeUnit

/**
 * Executes commands inside the embedded Linux environment using proot.
 * Command strings are treated as trusted (Studio power tool).
 */
class ProotExecutor(
    private val context: Context,
    private val bootstrapManager: BootstrapManager
) {

    companion object {
        private const val DEFAULT_TIMEOUT_SEC = 60L
        private const val MAX_OUTPUT_BYTES = 2 * 1024 * 1024 // 2 MB
        private const val MAX_TIMEOUT_SEC = 3600L
    }

    data class CommandResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean = false
    )

    private fun safeWorkingDir(raw: String?): String {
        val defaultGuest = "/home"
        if (raw.isNullOrBlank()) return defaultGuest

        val sanitized = raw.replace('\\', '/')
            .replace(Regex("/+"), "/")
            .trim()

        if (sanitized.contains("..")) {
            RuntimeLogger.w("workingDir rejected (contains ..): $raw")
            return defaultGuest
        }

        val guest = if (sanitized.startsWith("/")) sanitized else "/home/$sanitized"
        val normalized = try {
            Paths.get(guest).normalize().toString()
        } catch (_: Exception) {
            return defaultGuest
        }

        val blocked = listOf(
            "/data", "/system", "/vendor", "/proc", "/dev", "/sys",
            "/acct", "/mnt", "/storage", "/sdcard", "/self"
        )
        for (b in blocked) {
            if (normalized == b || normalized.startsWith("$b/")) {
                RuntimeLogger.w("workingDir rejected (blocked): $raw -> $normalized")
                return defaultGuest
            }
        }
        return normalized
    }

    fun run(
        command: String,
        workingDir: String? = null,
        timeoutSec: Long = DEFAULT_TIMEOUT_SEC
    ): CommandResult {
        val effectiveTimeout = when {
            timeoutSec <= 0L -> DEFAULT_TIMEOUT_SEC
            timeoutSec > MAX_TIMEOUT_SEC -> MAX_TIMEOUT_SEC
            else -> timeoutSec
        }

        if (!bootstrapManager.isReady) {
            return CommandResult(-1, "", "Runtime not ready. Call initialize() first.", false)
        }

        val prefix = bootstrapManager.prefixDir.canonicalFile
        val runtimeRoot = File(bootstrapManager.getRuntimeRootPath()).canonicalFile
        val nativeLibDir = context.applicationInfo.nativeLibraryDir
        val guestWorkDir = safeWorkingDir(workingDir)

        val prootCandidates = listOf(
            File(nativeLibDir, "libproot.so"),
            File(nativeLibDir, "proot"),
            File(prefix, "bin/proot"),
            File(prefix, "usr/bin/proot")
        )
        val actualProotFile = prootCandidates.firstOrNull { it.exists() && it.canExecute() }
            ?: return CommandResult(-1, "", "proot binary not found or not executable", false)

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

        val prootArgs = listOf(
            actualProot, "-0",
            "-r", prefix.absolutePath,
            "-b", "/dev", "-b", "/proc", "-b", "/sys",
            "-b", "${runtimeRoot.absolutePath}/tmp:/tmp",
            "-b", "${runtimeRoot.absolutePath}/home:/home",
            "-w", guestWorkDir,
            "/bin/sh", "-c", command
        )

        RuntimeLogger.d("Executing proot (cmdLen=${command.length}, cwd=$guestWorkDir)")

        var process: Process? = null
        val stdoutStream: java.io.InputStream
        val stderrStream: java.io.InputStream

        try {
            val pb = ProcessBuilder(prootArgs)
            pb.environment().clear()
            pb.environment().putAll(env)
            pb.redirectErrorStream(false)
            process = pb.start()
            stdoutStream = process.inputStream
            stderrStream = process.errorStream

            val stdout = StringBuilder()
            val stderr = StringBuilder()

            // Drain fully always (discard after cap) so child never blocks on full pipe
            val stdoutThread = Thread {
                drainCapped(stdoutStream, stdout)
            }.apply { name = "nexus-proot-stdout"; isDaemon = true }

            val stderrThread = Thread {
                drainCapped(stderrStream, stderr)
            }.apply { name = "nexus-proot-stderr"; isDaemon = true }

            stdoutThread.start()
            stderrThread.start()

            val finished = process.waitFor(effectiveTimeout, TimeUnit.SECONDS)

            if (!finished) {
                killProcessTree(process)
                stdoutThread.join(1500)
                stderrThread.join(1500)
                return CommandResult(
                    -1,
                    stdout.toString().trim(),
                    (stderr.toString().trim() + "\n[Timeout after ${effectiveTimeout}s]").trim(),
                    timedOut = true
                )
            }

            stdoutThread.join(2000)
            stderrThread.join(2000)

            return CommandResult(
                process.exitValue(),
                stdout.toString().trim(),
                stderr.toString().trim(),
                timedOut = false
            )
        } catch (e: Exception) {
            RuntimeLogger.e("Execution failed", e)
            process?.let { killProcessTree(it) }
            return CommandResult(-1, "", "Execution error: ${e.message}", false)
        } finally {
            try { process?.inputStream?.close() } catch (_: Exception) {}
            try { process?.errorStream?.close() } catch (_: Exception) {}
            try { process?.outputStream?.close() } catch (_: Exception) {}
        }
    }

    /**
     * Always drain the stream to EOF so the child never blocks on a full pipe.
     * Uses InputStreamReader so multi-byte UTF-8 sequences are not split across chunks.
     * Only the first MAX_OUTPUT_BYTES (approx via char budget) are kept in [out].
     */
    private fun drainCapped(stream: java.io.InputStream, out: StringBuilder) {
        try {
            java.io.InputStreamReader(stream, Charsets.UTF_8).use { reader ->
                val buf = CharArray(8192)
                var totalChars = 0
                var truncated = false
                while (true) {
                    val n = reader.read(buf)
                    if (n == -1) break
                    if (!truncated) {
                        if (totalChars + n <= MAX_OUTPUT_BYTES) {
                            out.append(buf, 0, n)
                            totalChars += n
                        } else {
                            val remain = MAX_OUTPUT_BYTES - totalChars
                            if (remain > 0) out.append(buf, 0, remain)
                            out.append("\n[output truncated at $MAX_OUTPUT_BYTES chars]")
                            truncated = true
                            // keep reading & discarding so pipe drains
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // stream closed
        }
    }

    private fun killProcessTree(process: Process) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                process.toHandle().descendants().forEach { h ->
                    try { h.destroyForcibly() } catch (_: Exception) {}
                }
                try {
                    val pid = process.toHandle().pid()
                    val killProc = Runtime.getRuntime().exec(
                        arrayOf(
                            "sh", "-c",
                            "kill -TERM -$pid 2>/dev/null || true; sleep 0.2; kill -KILL -$pid 2>/dev/null || true; kill -KILL $pid 2>/dev/null || true"
                        )
                    )
                    try {
                        killProc.waitFor(2, TimeUnit.SECONDS)
                    } finally {
                        try { killProc.inputStream.close() } catch (_: Exception) {}
                        try { killProc.outputStream.close() } catch (_: Exception) {}
                        try { killProc.errorStream.close() } catch (_: Exception) {}
                        try { killProc.destroyForcibly() } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
        try { process.destroyForcibly() } catch (_: Exception) {}
    }
}
