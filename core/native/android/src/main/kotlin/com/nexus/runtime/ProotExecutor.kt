package com.nexus.runtime

import android.content.Context
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

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
        private const val TAG = "NexusProot"
        private const val DEFAULT_TIMEOUT_SEC = 60L
    }

    data class CommandResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean = false
    )

    /**
     * Run a command inside the proot environment.
     *
     * @param command  The command to run (e.g. "python3 --version" or "ls -la")
     * @param workingDir  Optional working directory inside the guest
     * @param timeoutSec  Timeout in seconds
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
                stderr = "Runtime not ready. Call ensureBootstrap() first.",
                timedOut = false
            )
        }

        val prefix = bootstrapManager.prefixDir
        val runtimeRoot = File(bootstrapManager.getRuntimeRootPath())
        val nativeLibDir = context.applicationInfo.nativeLibraryDir

        val prootPath = File(nativeLibDir, "libproot.so").absolutePath
        val loaderPath = File(nativeLibDir, "libproot-loader.so").absolutePath

        // Fallback if renamed
        val actualProot = when {
            File(prootPath).exists() -> prootPath
            File(nativeLibDir, "proot").exists() -> File(nativeLibDir, "proot").absolutePath
            else -> prootPath
        }

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

        val prootArgs = mutableListOf<String>().apply {
            add(actualProot)
            add("-0")                          // fake root
            add("-r")
            add(prefix.absolutePath)           // rootfs
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

        Log.d(TAG, "Executing: ${prootArgs.joinToString(" ")}")

        return try {
            val processBuilder = ProcessBuilder(prootArgs)
            processBuilder.environment().clear()
            processBuilder.environment().putAll(env)
            processBuilder.redirectErrorStream(false)

            val process = processBuilder.start()

            val stdout = StringBuilder()
            val stderr = StringBuilder()

            val stdoutThread = Thread {
                BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                    reader.forEachLine { stdout.appendLine(it) }
                }
            }
            val stderrThread = Thread {
                BufferedReader(InputStreamReader(process.errorStream)).use { reader ->
                    reader.forEachLine { stderr.appendLine(it) }
                }
            }

            stdoutThread.start()
            stderrThread.start()

            val finished = process.waitFor(timeoutSec, TimeUnit.SECONDS)

            if (!finished) {
                process.destroyForcibly()
                stdoutThread.join(1000)
                stderrThread.join(1000)
                return CommandResult(
                    exitCode = -1,
                    stdout = stdout.toString(),
                    stderr = stderr.toString() + "\n[Timeout after ${timeoutSec}s]",
                    timedOut = true
                )
            }

            stdoutThread.join()
            stderrThread.join()

            CommandResult(
                exitCode = process.exitValue(),
                stdout = stdout.toString().trim(),
                stderr = stderr.toString().trim(),
                timedOut = false
            )
        } catch (e: Exception) {
            Log.e(TAG, "Execution failed", e)
            CommandResult(
                exitCode = -1,
                stdout = "",
                stderr = "Execution error: ${e.message}",
                timedOut = false
            )
        }
    }

    /**
     * Convenience: run and return only stdout (throws on non-zero exit)
     */
    fun runChecked(command: String): String {
        val result = run(command)
        if (result.exitCode != 0) {
            throw RuntimeException("Command failed (${result.exitCode}): ${result.stderr}")
        }
        return result.stdout
    }
}