package com.nexus.runtime

import android.content.Context
import java.io.File
import java.nio.file.Paths
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Executes commands inside the embedded Linux environment using proot.
 */
class ProotExecutor(
    private val context: Context,
    private val bootstrapManager: BootstrapManager
) {

    companion object {
        private const val DEFAULT_TIMEOUT_SEC = 60L
        private const val MAX_OUTPUT_CHARS = 2 * 1024 * 1024
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

    /** Shell form (trusted callers). */
    fun run(
        command: String,
        workingDir: String? = null,
        timeoutSec: Long = DEFAULT_TIMEOUT_SEC
    ): CommandResult {
        if (command.isBlank()) {
            return CommandResult(-1, "", "empty command", false)
        }
        val guestWorkDir = safeWorkingDir(workingDir)
        return execute(
            guestArgv = listOf("/bin/sh", "-c", command),
            extraProotArgs = emptyList(),
            guestWorkDir = guestWorkDir,
            timeoutSec = timeoutSec
        )
    }

    /**
     * Argv form — no shell. Used for project Run.
     * [extraProotArgs] typically: -b host:/home/project -w /home/project
     */
    fun runGuest(
        guestArgv: List<String>,
        extraProotArgs: List<String> = emptyList(),
        timeoutSec: Long = DEFAULT_TIMEOUT_SEC
    ): CommandResult {
        if (guestArgv.isEmpty()) {
            return CommandResult(-1, "", "empty guest argv", false)
        }
        // When extra args include -w, pass a placeholder work dir that won't be used
        val hasW = extraProotArgs.contains("-w")
        return execute(
            guestArgv = guestArgv,
            extraProotArgs = extraProotArgs,
            guestWorkDir = if (hasW) ProjectMount.GUEST_DIR else "/home",
            timeoutSec = timeoutSec,
            skipDefaultW = hasW
        )
    }

    private fun execute(
        guestArgv: List<String>,
        extraProotArgs: List<String>,
        guestWorkDir: String,
        timeoutSec: Long,
        skipDefaultW: Boolean = false
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

        val prootArgs = mutableListOf(
            actualProot, "-0",
            "-r", prefix.absolutePath,
            "-b", "/dev", "-b", "/proc", "-b", "/sys",
            "-b", "${runtimeRoot.absolutePath}/tmp:/tmp",
            "-b", "${runtimeRoot.absolutePath}/home:/home"
        )
        // Project bind etc. before -w / program
        prootArgs.addAll(extraProotArgs)
        if (!skipDefaultW) {
            prootArgs.add("-w")
            prootArgs.add(guestWorkDir)
        }
        prootArgs.addAll(guestArgv)

        RuntimeLogger.d("Executing proot argv=${guestArgv.take(4)} extra=${extraProotArgs.size}")

        var process: Process? = null
        val stdout = StringBuilder()
        val stderr = StringBuilder()
        val readerExecutor = Executors.newFixedThreadPool(2) { r ->
            Thread(r, "nexus-proot-reader").apply { isDaemon = true }
        }

        try {
            val pb = ProcessBuilder(prootArgs)
            pb.environment().clear()
            pb.environment().putAll(env)
            pb.redirectErrorStream(false)
            process = pb.start()

            val stdoutFuture = readerExecutor.submit {
                drainCapped(process!!.inputStream, stdout)
            }
            val stderrFuture = readerExecutor.submit {
                drainCapped(process!!.errorStream, stderr)
            }

            val finished = process!!.waitFor(effectiveTimeout, TimeUnit.SECONDS)

            if (!finished) {
                killProcessTree(process!!)
            }

            try { process?.inputStream?.close() } catch (_: Exception) {}
            try { process?.errorStream?.close() } catch (_: Exception) {}
            try { process?.outputStream?.close() } catch (_: Exception) {}

            try { stdoutFuture.get(2, TimeUnit.SECONDS) } catch (_: Exception) {}
            try { stderrFuture.get(2, TimeUnit.SECONDS) } catch (_: Exception) {}

            val timedOut = !finished
            val exitCode = if (timedOut) -1 else try {
                process!!.exitValue()
            } catch (_: Exception) {
                -1
            }
            val errExtra = if (timedOut) "\n[Timeout after ${effectiveTimeout}s]" else ""

            return CommandResult(
                exitCode,
                stdout.toString().trim(),
                (stderr.toString().trim() + errExtra).trim(),
                timedOut = timedOut
            )
        } catch (e: Exception) {
            RuntimeLogger.e("Execution failed", e)
            process?.let { killProcessTree(it) }
            return CommandResult(-1, "", "Execution error: ${e.message}", false)
        } finally {
            try { process?.inputStream?.close() } catch (_: Exception) {}
            try { process?.errorStream?.close() } catch (_: Exception) {}
            try { process?.outputStream?.close() } catch (_: Exception) {}
            readerExecutor.shutdownNow()
            try {
                readerExecutor.awaitTermination(2, TimeUnit.SECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

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
                        if (totalChars + n <= MAX_OUTPUT_CHARS) {
                            out.append(buf, 0, n)
                            totalChars += n
                        } else {
                            val remain = MAX_OUTPUT_CHARS - totalChars
                            if (remain > 0) out.append(buf, 0, remain)
                            out.append("\n[output truncated at $MAX_OUTPUT_CHARS chars]")
                            truncated = true
                        }
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    /**
     * Best-effort kill of proot and children.
     * Avoid Process.toHandle()/ProcessHandle — not in the Android SDK stubs,
     * so it fails compileDebugKotlin even when minSdk is 26+.
     */
    private fun killProcessTree(process: Process) {
        val pid = processPid(process)
        if (pid != null && pid > 0) {
            var killer: Process? = null
            try {
                // Kill process group if any, then the pid itself.
                killer = Runtime.getRuntime().exec(
                    arrayOf(
                        "sh", "-c",
                        "kill -TERM -$pid 2>/dev/null || true; " +
                            "kill -TERM $pid 2>/dev/null || true; " +
                            "sleep 0.15; " +
                            "kill -KILL -$pid 2>/dev/null || true; " +
                            "kill -KILL $pid 2>/dev/null || true"
                    )
                )
                killer.waitFor(2, TimeUnit.SECONDS)
            } catch (_: Exception) {
            } finally {
                try { killer?.inputStream?.close() } catch (_: Exception) {}
                try { killer?.outputStream?.close() } catch (_: Exception) {}
                try { killer?.errorStream?.close() } catch (_: Exception) {}
                try { killer?.destroyForcibly() } catch (_: Exception) {}
            }
        }
        try { process.destroy() } catch (_: Exception) {}
        try { process.destroyForcibly() } catch (_: Exception) {}
    }

    /** Reflective pid for Android's java.lang.Process (no public API on all levels). */
    private fun processPid(process: Process): Long? {
        return try {
            val m = process.javaClass.methods.firstOrNull {
                it.name == "pid" && it.parameterCount == 0
            }
            if (m != null) {
                m.isAccessible = true
                return (m.invoke(process) as? Number)?.toLong()
            }
            val f = process.javaClass.getDeclaredField("pid")
            f.isAccessible = true
            (f.get(process) as? Number)?.toLong()
        } catch (_: Exception) {
            null
        }
    }
}

