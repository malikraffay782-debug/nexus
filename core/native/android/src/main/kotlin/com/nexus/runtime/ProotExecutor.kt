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

        // Optional extras — make readable if present
        for (name in listOf("libproot-loader32.so", "libproot-userland.so")) {
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

        // host-lib kept for diagnostics; static proot needs no talloc staging
        val hostLibDir = File(runtimeRoot, "host-lib").also { it.mkdirs() }

        val termuxPrefix = "/data/data/com.termux/files/usr"
        val termuxHome = "/data/data/com.termux/files/home"
        val hostTmp = File(runtimeRoot, "tmp")
        hostTmp.mkdirs()
        // Proot writes probe files under PROOT_TMP_DIR; must exist before spawn
        // or chmod fails with "No such file or directory".
        if (!hostTmp.isDirectory) {
            return CommandResult(-1, "", "Cannot create PROOT_TMP_DIR at ${hostTmp.absolutePath}", false)
        }
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

        // Verify guest /bin/sh exists before spawning (avoids opaque SIGSEGV).
        val guestSh = File(prefix, "bin/sh")
        if (!guestSh.exists()) {
            return CommandResult(
                -1, "",
                "Guest /bin/sh missing under ${prefix.absolutePath}. Bootstrap extract incomplete — re-Initialize.",
                false
            )
        }

        // Static proot (green-green-avk) only needs system libc/libdl.
        // Green-green-avk start scripts UNSET LD_LIBRARY_PATH — keep it empty
        // so OEM linkers don't chase missing Termux paths.
        val env = mutableMapOf<String, String>()
        env["PROOT_LOADER"] = loaderPath
        env["PROOT_TMP_DIR"] = File(runtimeRoot, "tmp").absolutePath
        // Do NOT set PROOT_NO_SECCOMP. On Android the zygote installs a seccomp
        // filter that returns ENOSYS for chmod/chdir/etc. Termux proot must
        // detect and handle SIGSYS; PROOT_NO_SECCOMP disables that path and
        // produces "Function not implemented" on execve/chmod/chdir.
        env["PREFIX"] = termuxPrefix
        env["HOME"] = termuxHome
        env["TMPDIR"] = "/tmp"
        env["PATH"] = "$termuxPrefix/bin:/bin:/usr/bin"
        env["TERM"] = "xterm-256color"
        env["LANG"] = "C.UTF-8"
        env["LD_PRELOAD"] = ""
        // Explicitly clear — do not inherit app LD_LIBRARY_PATH
        env["LD_LIBRARY_PATH"] = ""
        val ldPath = "(cleared)"

        // Termux aarch64 binaries use INTERP=/system/bin/linker64 and NEEDED=libc.so
        // (Android Bionic). Without binding /system (and usually /apex on API 29+),
        // execve("/bin/sh") fails with ENOENT even when prefix/bin/sh exists.
        // /sys is still avoided — it has caused SIGSEGV on some Vivo/MTK kernels.
        fun buildArgs(fakeRoot: Boolean): MutableList<String> {
            val args = mutableListOf(
                actualProot,
                "--link2symlink",
                "--kill-on-exit",
            )
            if (fakeRoot) args.add("-0")
            args.addAll(
                listOf(
                    "-r", prefix.absolutePath,
                    "-b", "/dev",
                    "-b", "/proc",
                    "-b", "/system",
                )
            )
            // Android 10+ puts Bionic libc/linker pieces under /apex
            if (File("/apex").isDirectory) {
                args.add("-b")
                args.add("/apex")
            }
            // Vendor libs on some OEMs
            if (File("/vendor").isDirectory) {
                args.add("-b")
                args.add("/vendor")
            }
            args.addAll(
                listOf(
                    "-b", "${runtimeRoot.absolutePath}/tmp:/tmp",
                    "-b", "${runtimeRoot.absolutePath}/home:$termuxHome",
                    "-b", "${runtimeRoot.absolutePath}/home:/home",
                )
            )
            args.addAll(extraProotArgs)
            if (!skipDefaultW) {
                args.add("-w")
                args.add(guestWorkDir)
            }
            args.addAll(guestArgv)
            return args
        }

        // Try with -0 first (Termux default). On hard SIGSEGV, one retry without -0.
        var prootArgs = buildArgs(fakeRoot = true)
        RuntimeLogger.d(
            "Executing proot from=$actualProot loader=$loaderPath " +
                "rootfs=${prefix.absolutePath} hostLib=${hostLibDir.absolutePath} " +
                "argv=${guestArgv.take(3)}"
        )

        // Run once with -0; on SIGSEGV, one automatic retry without -0.
        var last = spawnOnce(prootArgs, nativeDir, env, effectiveTimeout)
        if ((last.exitCode == 139 || last.exitCode == -11) && !last.stoppedByUser && !last.timedOut) {
            RuntimeLogger.w("proot SIGSEGV with -0; retrying without fake-root")
            prootArgs = buildArgs(fakeRoot = false)
            last = spawnOnce(prootArgs, nativeDir, env, effectiveTimeout)
        }

        var errText = last.stderr
        if (errText.contains("CANNOT LINK EXECUTABLE") ||
            (errText.contains("library \"") && errText.contains("not found"))
        ) {
            errText = errText + "\n\nHint: native dependency missing from APK jniLibs. " +
                "Rebuild APK with static proot (green-green-avk) and reinstall after uninstall."
        }
        if (last.exitCode == 139 || last.exitCode == -11) {
            errText = (errText + "\n\n[proot SIGSEGV] host=" + actualProot +
                " loader=" + loaderPath +
                " rootfs=" + prefix.absolutePath +
                " hostLib=" + hostLibDir.absolutePath +
                " ld=" + ldPath).trim()
        }
        return CommandResult(
            last.exitCode,
            last.stdout,
            errText,
            timedOut = last.timedOut,
            stoppedByUser = last.stoppedByUser
        )
    }

    /**
     * App-private dir with versioned soname symlinks so the dynamic linker can
     * resolve libtalloc.so.2 even when only libtalloc.so was shipped in jniLibs.
     */
    private fun ensureHostLibStaging(nativeDir: File, runtimeRoot: File): File {
        val hostLib = File(runtimeRoot, "host-lib")
        if (!hostLib.exists()) hostLib.mkdirs()
        val pairs = listOf(
            "libtalloc.so.2" to "libtalloc.so",
            "libtalloc.so.2.5.0" to "libtalloc.so",
            "libandroid-shmem.so" to "libandroid-shmem.so",
            "libtalloc.so" to "libtalloc.so",
        )
        for ((linkName, targetName) in pairs) {
            val target = File(nativeDir, targetName)
            if (!target.isFile) continue
            val link = File(hostLib, linkName)
            try {
                if (link.exists()) {
                    // Refresh if broken or pointing elsewhere
                    if (link.canonicalFile != target.canonicalFile) {
                        link.delete()
                    } else {
                        continue
                    }
                }
                // Prefer real symlink; fall back to a byte copy if symlink blocked.
                try {
                    android.system.Os.symlink(target.absolutePath, link.absolutePath)
                } catch (_: Throwable) {
                    target.inputStream().use { input ->
                        link.outputStream().use { output -> input.copyTo(output) }
                    }
                    link.setReadable(true)
                }
            } catch (e: Exception) {
                RuntimeLogger.w("host-lib staging $linkName: ${e.message}")
            }
        }
        return hostLib
    }

    private data class SpawnResult(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
        val timedOut: Boolean,
        val stoppedByUser: Boolean
    )

    private fun spawnOnce(
        prootArgs: List<String>,
        nativeDir: File,
        env: Map<String, String>,
        effectiveTimeout: Long
    ): SpawnResult {
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
            return SpawnResult(
                exitCode,
                stdout.toString().trim(),
                (stderr.toString().trim() + errExtra).trim(),
                timedOut = timedOut,
                stoppedByUser = stopRequested && !timedOut
            )
        } catch (e: Exception) {
            RuntimeLogger.e("Execution failed", e)
            process?.let { killProcessTree(it) }
            return SpawnResult(-1, "", "Execution error: ${e.message}", false, false)
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
     *   libproot.so, libproot-loader.so
     *
     * We ship green-green-avk static proot (talloc linked in). No libtalloc.so
     * required — that dynamic dependency caused SIGSEGV on Vivo/MTK devices.
     */
    private fun missingNativeDeps(nativeLibDir: String): String? {
        val dir = File(nativeLibDir)
        fun regularReadable(name: String): Boolean {
            val f = File(dir, name)
            return f.isFile && f.canRead()
        }
        for (name in listOf("libproot.so", "libproot-loader.so")) {
            if (!regularReadable(name)) {
                return "Missing native library: $name under $nativeLibDir. Rebuild APK with static proot jniLibs."
            }
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

