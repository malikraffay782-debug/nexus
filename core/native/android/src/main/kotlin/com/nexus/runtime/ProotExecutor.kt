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
 * Note: This is a powerful execution surface. Callers must treat the
 * command string as trusted. Full command allowlisting is a later phase.
 */
class ProotExecutor(
    private val context: Context,
    private val bootstrapManager: BootstrapManager
) {

    companion object {
        private const val DEFAULT_TIMEOUT_SEC = 60L
        private const val MAX_OUTPUT_BYTES = 2 * 1024 * 1024 // 2 MB
        private const val MAX_LINE_BYTES = 256 * 1024         // 256 KB per line hard stop
    }

    data class CommandResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean = false
    )

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

        val prefix = bootstrapManager.prefixDir
        val runtimeRoot = File(bootstrapManager.getRuntimeRootPath())
        val nativeLibDir = context.applicationInfo.nativeLibraryDir

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

        // Keep PATH mostly inside the prefix. Only fall back to /system/bin for a few
        // essential Android tools if needed; prefer prefix binaries.
        val env = mutableMapOf<String, String>()
        env["PROOT_LOADER"] = loaderPath
        env["PROOT_TMP_DIR"] = File(runtimeRoot, "tmp").absolutePath
        env["PREFIX"] = prefix.absolutePath
        env["HOME"] = File(runtimeRoot, "home").absolutePath
        env["TMPDIR"] = File(runtimeRoot, "tmp").absolutePath
        env["PATH"] = "${prefix.absolutePath}/bin:${prefix.absolutePath}/usr/bin"
        // Prefer prefix libs; include nativeLibDir only for proot loader itself
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
            add(workingDir ?: "/home")
            add("/bin/sh")
            add("-c")
            add(command)
        }

        RuntimeLogger.d("Executing proot (cmd length=${command.length})")

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

    /**
     * Read stream with hard byte and per-line limits.
     * Stops reading once the cap is hit (does not keep buffering forever).
     */
    private fun readCapped(stream: java.io.InputStream, out: StringBuilder) {
        try {
            val reader = BufferedReader(InputStreamReader(stream))
            var total = 0
            val lineBuf = StringBuilder()
            while (true) {
                val ch = reader.read()
                if (ch == -1) break

                if (ch == '\n'.code) {
                    val line = lineBuf.toString()
                    lineBuf.setLength(0)
                    total += line.length + 1
                    if (total > MAX_OUTPUT_BYTES) {
                        out.appendLine("\n[output truncated at $MAX_OUTPUT_BYTES bytes]")
                        break
                    }
                    out.appendLine(line)
                } else {
                    lineBuf.append(ch.toChar())
                    // Hard stop on giant lines without newline
                    if (lineBuf.length > MAX_LINE_BYTES) {
                        out.appendLine("\n[line truncated at $MAX_LINE_BYTES bytes]")
                        total += lineBuf.length
                        lineBuf.setLength(0)
                        if (total > MAX_OUTPUT_BYTES) break
                        // skip rest of this line
                        while (true) {
                            val c2 = reader.read()
                            if (c2 == -1 || c2 == '\n'.code) break
                        }
                    }
                }
            }
            // leftover without trailing newline
            if (lineBuf.isNotEmpty() && total <= MAX_OUTPUT_BYTES) {
                out.append(lineBuf)
            }
        } catch (_: Exception) {
            // process closed / stream ended
        }
    }

    /**
     * Best-effort kill of the process and its descendants (API 24+).
     */
    private fun killProcessTree(process: Process) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                process.toHandle().descendants().forEach { handle ->
                    try { handle.destroyForcibly() } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}
        try {
            process.destroyForcibly()
        } catch (_: Exception) {}
    }
}
