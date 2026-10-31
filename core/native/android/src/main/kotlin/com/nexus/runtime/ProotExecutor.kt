package com.nexus.runtime

import android.content.Context
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Executes commands inside the embedded Linux environment using proot.
 *
 * Critical: proot-loader must be loaded from nativeLibraryDir to satisfy
 * Android's W^X restrictions.
 */
class ProotExecutor(
    private val context: Context,
    private val bootstrapManager: BootstrapManager
) {

    companion object {
        private const val DEFAULT_TIMEOUT_SEC = 60L
        private const val MAX_OUTPUT_BYTES = 2 * 1024 * 1024 // 2 MB cap
    }

    data class CommandResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean = false
    )

    /**
     * Run a command inside the proot environment.
     */
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
        val actualProot = prootCandidates.firstOrNull { it.exists() }?.absolutePath
            ?: File(nativeLibDir, "libproot.so").absolutePath

        val loaderPath = File(nativeLibDir, "libproot-loader.so").absolutePath

        val env = mutableMapOf<String, String>()
        env["PROOT_LOADER"] = loaderPath
        env["PROOT_TMP_DIR"] = File(runtimeRoot, "tmp").absolutePath
        env["PREFIX"] = prefix.absolutePath
        env["HOME"] = File(runtimeRoot, "home").absolutePath
        env["TMPDIR"] = File(runtimeRoot, "tmp").absolutePath
        env["PATH"] = "${prefix.absolutePath}/bin:${prefix.absolutePath}/usr/bin:/system/bin"
        env["LD_LIBRARY_PATH"] = "${prefix.absolutePath}/lib:${nativeLibDir}"
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        // Helpful Android-related vars some tools expect
        env["ANDROID_DATA"] = "/data"
        env["ANDROID_ROOT"] = "/system"

        val prootArgs = mutableListOf<String>().apply {
            add(actualProot)
            add("-0")                          // fake root
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

        RuntimeLogger.d("Executing: ${prootArgs.joinToString(" ")}")

        return try {
            val processBuilder = ProcessBuilder(prootArgs)
            processBuilder.environment().clear()
            processBuilder.environment().putAll(env)
            processBuilder.redirectErrorStream(false)

            val process = processBuilder.start()
            val finishedFlag = AtomicBoolean(false)

            val stdout = StringBuilder()
            val stderr = StringBuilder()

            val stdoutThread = Thread {
                try {
                    BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                        var total = 0
                        while (true) {
                            val line = reader.readLine() ?: break
                            total += line.length + 1
                            if (total > MAX_OUTPUT_BYTES) {
                                stdout.appendLine("\n[output truncated at ${MAX_OUTPUT_BYTES} bytes]")
                                break  // stop reading – does not consume unbounded memory in the builder
                            }
                            stdout.appendLine(line)
                        }
                    }
                } catch (_: Exception) { /* process closed */ }
            }.apply { name = "nexus-proot-stdout"; isDaemon = true }

            val stderrThread = Thread {
                try {
                    BufferedReader(InputStreamReader(process.errorStream)).use { reader ->
                        var total = 0
                        while (true) {
                            val line = reader.readLine() ?: break
                            total += line.length + 1
                            if (total > MAX_OUTPUT_BYTES) {
                                stderr.appendLine("\n[output truncated at ${MAX_OUTPUT_BYTES} bytes]")
                                break
                            }
                            stderr.appendLine(line)
                        }
                    }
                } catch (_: Exception) { /* process closed */ }
            }.apply { name = "nexus-proot-stderr"; isDaemon = true }

            stdoutThread.start()
            stderrThread.start()

            val finished = process.waitFor(timeoutSec, TimeUnit.SECONDS)
            finishedFlag.set(true)

            if (!finished) {
                // Best effort kill
                process.destroyForcibly()
                // Give reader threads a short chance to finish
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
}