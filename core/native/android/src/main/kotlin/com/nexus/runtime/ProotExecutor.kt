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
    /** Current proot Process; written only on the run thread, read by stopActive(). */
    @Volatile
    private var activeProcess: Process? = null

    /** Set by stopActive(); execute() reports stoppedByUser when true. */
    @Volatile
    private var stopRequested: Boolean = false


    companion object {
        private const val DEFAULT_TIMEOUT_SEC = 60L
        private const val MAX_OUTPUT_CHARS = 2 * 1024 * 1024
        private const val MAX_TIMEOUT_SEC = 3600L
    }

    data class CommandResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean = false,
        val stoppedByUser: Boolean = false
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

        // Android 10+ W^X: cannot exec from filesDir (error=13). Always run from
        // nativeLibraryDir where the system extracted jniLibs (extractNativeLibs=true).
        val nativeDir = File(nativeLibDir)
        val actualProotFile = File(nativeDir, "libproot.so")
        if (!actualProotFile.isFile) {
            return CommandResult(-1, "", "libproot.so not found under $nativeLibDir", false)
        }
        try {
            actualProotFile.setReadable(true)
            actualProotFile.setExecutable(true)
        } catch (_: Exception) {}
        val actualProot = actualProotFile.absolutePath

        val loaderFile = File(nativeDir, "libproot-loader.so")
        if (!loaderFile.isFile) {
            return CommandResult(-1, "", "libproot-loader.so not found under $nativeLibDir", false)
        }
        try {
            loaderFile.setReadable(true)
            loaderFile.setExecutable(true)
        } catch (_: Exception) {}
        val loaderPath = loaderFile.absolutePath

        // Ensure sibling deps are readable for the dynamic linker
        for (name in listOf("libtalloc.so", "libandroid-shmem.so", "libproot-loader32.so")) {
            val f = File(nativeDir, name)
            if (f.isFile) {
                try {
                    f.setReadable(true)
                    f.setExecutable(true)
                } catch (_: Exception) {}
            }
        }

        val missingNative = missingNativeDeps(nativeLibDir)
        if (missingNative != null) {
            return CommandResult(-1, "", missingNative, false)
        }

        val termuxPrefix = "/data/data/com.termux/files/usr"
        val termuxHome = "/data/data/com.termux/files/home"
        File(runtimeRoot, "tmp").mkdirs()
        File(runtimeRoot, "home").mkdirs()
        File(prefix, "tmp").mkdirs()
        try {
            val resolv = File(prefix, "etc/resolv.conf")
            resolv.parentFile?.mkdirs()
            if (!resolv.isFile || resolv.length() < 8L) {
                resolv.writeText("nameserver 8.8.8.8\nnameserver 1.1.1.1\n")
            }
        } catch (e: Exception) {
            RuntimeLogger.w("Could not write resolv.conf: ${e.message}")
        }
        val layoutOk = try {
            bootstrapManager.ensureTermuxPathLayout()
        } catch (e: Exception) {
            RuntimeLogger.w("ensureTermuxPathLayout: ${e.message}")
            false
        }
        if (!layoutOk) {
            return CommandResult(
                -1, "",
                "Runtime path layout incomplete (Termux PREFIX symlink). Re-run Initialize or reinstall APK.",
                false
            )
        }

        // Do NOT clear the process environment — OEM linkers on low-end devices
        // can SIGSEGV when required Android env vars disappear.
        // LD_LIBRARY_PATH must point at nativeLibraryDir so the (now $ORIGIN) proot
        // + loader can still resolve libtalloc / libandroid-shmem even if rpath
        // handling is imperfect on some OEM linkers.
        val env = mutableMapOf<String, String>()
        env["PROOT_LOADER"] = loaderPath
        env["PROOT_TMP_DIR"] = File(runtimeRoot, "tmp").absolutePath
        env["PROOT_NO_SECCOMP"] = "1"
        env["PREFIX"] = termuxPrefix
        env["HOME"] = termuxHome
        env["TMPDIR"] = "/tmp"
        env["PATH"] = "$termuxPrefix/bin:/bin:/usr/bin"
        env["LD_LIBRARY_PATH"] = nativeLibDir
        env["TERM"] = "xterm-256color"
        env["LANG"] = "C.UTF-8"
        // Helps some MediaTek linkers that otherwise crash while resolving
        // the rewritten sonames.
        env["LD_PRELOAD"] = ""

        // Minimal binds only — /sys /system /apex crash proot on some Vivo/MTK devices.
        // Keep -0 (fake root); most Termux packages expect it. If a future device
        // still SIGSEGVs we can gate it behind a probe flag.
        val prootArgs = mutableListOf(
            actualProot,
            "--link2symlink",
            "-0",
            "-r", prefix.absolutePath,
            "-b", "/dev",
            "-b", "/proc",
            "-b", "${runtimeRoot.absolutePath}/tmp:/tmp",
            "-b", "${runtimeRoot.absolutePath}/home:$termuxHome",
            "-b", "${runtimeRoot.absolutePath}/home:/home",
        )
        // Project bind etc. before -w / program
        prootArgs.addAll(extraProotArgs)
        if (!skipDefaultW) {
            prootArgs.add("-w")
            prootArgs.add(guestWorkDir)
        }
        prootArgs.addAll(guestArgv)

        RuntimeLogger.d(
            "Executing proot from=$actualProot loader=$loaderPath " +
                "rootfs=${prefix.absolutePath} argv=${guestArgv.take(3)}"
        )

        var process: Process? = null
        val stdout = StringBuilder()
        val stderr = StringBuilder()
        val readerExecutor = Executors.newFixedThreadPool(2) { r ->
            Thread(r, "nexus-proot-reader").apply { isDaemon = true }
        }

        try {
            val pb = ProcessBuilder(prootArgs)
            // Start in nativeLibraryDir so relative $ORIGIN lookups are well-defined.
            pb.directory(nativeDir)
            // Merge, do not clear — preserve Android linker-related env on low-end OEMs.
            val pbEnv = pb.environment()
            pbEnv.putAll(env)
            pb.redirectErrorStream(false)
            stopRequested = false
            process = pb.start()
            activeProcess = process

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
            var errText = (stderr.toString().trim() + errExtra).trim()
            // Linker failures are common when a soname is missing from the APK.
            if (errText.contains("CANNOT LINK EXECUTABLE") || (errText.contains("library \"") && errText.contains("not found"))) {
                errText = errText + "\n\nHint: native dependency missing from APK jniLibs. " +
                    "Rebuild APK (need libtalloc.so + patchelf proot) and reinstall after uninstall."
            }


            if (exitCode == 139 || exitCode == -11) {
                errText = (errText + "\n\n[proot SIGSEGV] host=" + actualProot +
                    " loader=" + loaderPath +
                    " rootfs=" + prefix.absolutePath +
                    " ld=" + nativeLibDir).trim()
            }

            val stopped = stopRequested && !timedOut
            return CommandResult(
                exitCode,
                stdout.toString().trim(),
                errText,
                timedOut = timedOut,
                stoppedByUser = stopped
            )
        } catch (e: Exception) {
            RuntimeLogger.e("Execution failed", e)
            process?.let { killProcessTree(it) }
            return CommandResult(-1, "", "Execution error: ${e.message}", false)
        } finally {
            activeProcess = null
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
     * Packaging contract (APK jniLibs/arm64-v8a):
     *   libproot.so, libproot-loader.so, libtalloc.so, libandroid-shmem.so
     *
     * Android only extracts lib*.so (not libfoo.so.2). CI patchelf's proot so
     * DT_NEEDED is libtalloc.so.
     */
    private fun missingNativeDeps(nativeLibDir: String): String? {
        val dir = File(nativeLibDir)
        fun regularReadable(name: String): Boolean {
            val f = File(dir, name)
            return f.isFile && f.canRead()
        }
        for (name in listOf("libproot.so", "libproot-loader.so", "libtalloc.so")) {
            if (!regularReadable(name)) {
                return "Missing native library: $name under $nativeLibDir. Rebuild APK with jniLibs."
            }
        }
        if (!regularReadable("libandroid-shmem.so")) {
            RuntimeLogger.w("libandroid-shmem.so not found in $nativeLibDir (may still work)")
        }
        return null
    }

    /**
     * Best-effort kill of proot and children.
     * Avoid Process.toHandle()/ProcessHandle — not in the Android SDK stubs,
     * so it fails compileDebugKotlin even when minSdk is 26+.
     */
    /**
     * Best-effort stop of the active proot process (TERM then KILL via killProcessTree).
     * Safe to call without holding runMutex; only signals the process.
     */
    fun stopActive(): Boolean {
        val p = activeProcess ?: return false
        stopRequested = true
        if (!p.isAlive) return false
        killProcessTree(p)
        return true
    }

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
                // Best-effort: process group may not apply; force-kill killer if it hangs.
                val killerDone = killer.waitFor(2, TimeUnit.SECONDS)
                if (!killerDone) {
                    try { killer.destroyForcibly() } catch (_: Exception) {}
                }
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

