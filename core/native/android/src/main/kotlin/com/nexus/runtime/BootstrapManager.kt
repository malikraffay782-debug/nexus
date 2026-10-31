package com.nexus.runtime

import android.content.Context
import android.os.Build
import android.system.Os
import java.io.BufferedReader
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.util.concurrent.locks.ReentrantLock
import java.util.zip.ZipInputStream
import kotlin.concurrent.withLock

/**
 * Handles first-run extraction of the Termux-style bootstrap.
 *
 * Official Termux bootstraps store symlink info in SYMLINKS.txt
 * (format: target←relativeLinkPath). We recreate them after extract.
 */
class BootstrapManager(private val context: Context) {

    companion object {
        private const val RUNTIME_DIR = "nexus-runtime"
        private const val PREFIX_DIR = "prefix"
        private const val VERSION_FILE = "version"
        const val CURRENT_BOOTSTRAP_VERSION = "2026.10.1"

        // Single lock for the whole ensureBootstrap sequence
        private val bootstrapLock = ReentrantLock()
    }

    private val runtimeRoot: File
        get() = File(context.filesDir, RUNTIME_DIR)

    val prefixDir: File
        get() = File(runtimeRoot, PREFIX_DIR)

    /**
     * Stronger readiness check.
     * Still not perfect (doesn't run proot), but much better than before.
     */
    val isReady: Boolean
        get() = try {
            val versionFile = File(runtimeRoot, VERSION_FILE)
            if (!versionFile.exists()) return false
            if (versionFile.readText().trim() != CURRENT_BOOTSTRAP_VERSION) return false

            val binDir = File(prefixDir, "bin")
            if (!binDir.isDirectory) return false

            // Critical files that must exist after a good extract
            val mustExist = listOf(
                File(prefixDir, "bin"),
                File(prefixDir, "etc"),
                File(prefixDir, "lib")
            )
            if (mustExist.any { !it.exists() }) return false

            // At least one of the common shells should be present (symlink or file)
            val sh = File(prefixDir, "bin/sh")
            if (!sh.exists()) return false

            true
        } catch (t: Throwable) {
            RuntimeLogger.e("isReady check failed", t)
            false
        }

    /**
     * Thread-safe bootstrap. Concurrent callers will wait / re-check.
     */
    fun ensureBootstrap(onProgress: ((Int, String) -> Unit)? = null): Result<Unit> {
        return bootstrapLock.withLock {
            try {
                if (isReady) {
                    RuntimeLogger.i("Bootstrap already ready (v$CURRENT_BOOTSTRAP_VERSION)")
                    onProgress?.invoke(100, "Already ready")
                    return@withLock Result.success(Unit)
                }

                RuntimeLogger.i("Starting bootstrap extraction...")
                onProgress?.invoke(5, "Preparing...")

                runtimeRoot.mkdirs()
                val arch = detectArch()
                RuntimeLogger.i("Architecture: $arch")
                onProgress?.invoke(10, "Detected $arch")

                val assetName = "bootstrap/bootstrap-$arch.zip"
                try {
                    context.assets.open(assetName).close()
                } catch (e: FileNotFoundException) {
                    val msg = "Bootstrap asset not found: $assetName"
                    RuntimeLogger.e(msg)
                    onProgress?.invoke(0, msg)
                    return@withLock Result.failure(FileNotFoundException(msg))
                }

                // Clean previous install
                if (prefixDir.exists()) {
                    onProgress?.invoke(15, "Cleaning old install...")
                    prefixDir.deleteRecursively()
                }
                prefixDir.mkdirs()

                extractBootstrap(arch, onProgress)
                createRequiredDirs()

                // Atomic-ish version write: write temp then rename
                writeVersionAtomic()

                onProgress?.invoke(100, "Done")
                RuntimeLogger.i("Bootstrap extraction completed")
                Result.success(Unit)
            } catch (e: Exception) {
                RuntimeLogger.e("Bootstrap failed", e)
                // Best effort: remove partial version so isReady stays false
                try { File(runtimeRoot, VERSION_FILE).delete() } catch (_: Exception) {}
                Result.failure(e)
            }
        }
    }

    private fun detectArch(): String {
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: Build.CPU_ABI
        return when {
            abi.startsWith("arm64") || abi == "aarch64" -> "aarch64"
            abi.startsWith("armeabi") || abi.startsWith("arm") -> "arm"
            abi.startsWith("x86_64") -> "x86_64"
            abi.startsWith("x86") -> "x86"
            else -> {
                RuntimeLogger.w("Unknown ABI '$abi', falling back to aarch64")
                "aarch64"
            }
        }
    }

    private fun extractBootstrap(arch: String, onProgress: ((Int, String) -> Unit)?) {
        val assetName = "bootstrap/bootstrap-$arch.zip"
        onProgress?.invoke(20, "Opening bootstrap...")

        val targetDir = prefixDir.canonicalFile
        val symlinks = mutableListOf<Pair<String, String>>() // target to linkAbs

        context.assets.open(assetName).use { input ->
            ZipInputStream(input).use { zis ->
                var entry = zis.nextEntry
                var count = 0
                while (entry != null) {
                    val name = entry.name

                    if (name == "SYMLINKS.txt" || name.endsWith("/SYMLINKS.txt")) {
                        BufferedReader(InputStreamReader(zis)).use { reader ->
                            var line = reader.readLine()
                            while (line != null) {
                                val parts = line.split("←")
                                if (parts.size == 2) {
                                    val target = parts[0].trim()
                                    val linkRel = parts[1].trim().removePrefix("./")

                                    // Validate link destination
                                    val linkAbsFile = File(targetDir, linkRel).canonicalFile
                                    if (!linkAbsFile.toPath().startsWith(targetDir.toPath())) {
                                        RuntimeLogger.w("Skipping unsafe symlink destination: $linkRel")
                                    } else if (!isSafeSymlinkTarget(target)) {
                                        RuntimeLogger.w("Skipping unsafe symlink target: $target")
                                    } else {
                                        symlinks.add(target to linkAbsFile.absolutePath)
                                    }
                                } else {
                                    RuntimeLogger.w("Malformed SYMLINKS line: $line")
                                }
                                line = reader.readLine()
                            }
                        }
                        zis.closeEntry()
                        entry = zis.nextEntry
                        continue
                    }

                    // Zip Slip protection
                    val outFile = File(targetDir, name).canonicalFile
                    if (!outFile.toPath().startsWith(targetDir.toPath())) {
                        throw SecurityException("Zip Slip blocked: $name")
                    }

                    if (entry.isDirectory) {
                        outFile.mkdirs()
                    } else {
                        outFile.parentFile?.mkdirs()
                        FileOutputStream(outFile).use { fos -> zis.copyTo(fos) }
                        if (name.startsWith("bin/") || name.startsWith("libexec/") || name.contains("/bin/")) {
                            outFile.setExecutable(true, false)
                        }
                    }

                    count++
                    if (count % 25 == 0) {
                        val pct = (20 + (count.coerceAtMost(800) * 60 / 800)).coerceAtMost(85)
                        onProgress?.invoke(pct, "Extracting... ($count files)")
                    }

                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
        }

        onProgress?.invoke(88, "Creating ${symlinks.size} symlinks...")
        RuntimeLogger.i("Creating ${symlinks.size} symlinks")

        var created = 0
        for ((target, linkAbs) in symlinks) {
            try {
                val linkFile = File(linkAbs)
                linkFile.parentFile?.mkdirs()
                if (linkFile.exists()) {
                    // Only delete if it's a regular file (not a directory)
                    if (linkFile.isFile) linkFile.delete()
                    else {
                        RuntimeLogger.w("Refusing to replace non-file at $linkAbs")
                        continue
                    }
                }
                Os.symlink(target, linkAbs)
                created++
            } catch (t: Throwable) {
                RuntimeLogger.w("Failed symlink $linkAbs -> $target : ${t.message}")
            }
        }
        RuntimeLogger.i("Created $created / ${symlinks.size} symlinks")
        File(targetDir, "bin").setExecutable(true, false)
        onProgress?.invoke(95, "Symlinks ready")
    }

    /**
     * Reject clearly dangerous symlink targets.
     * Allows relative targets and targets that stay under the prefix idea.
     * Blocks absolute paths outside a reasonable set and obvious host paths.
     */
    private fun isSafeSymlinkTarget(target: String): Boolean {
        if (target.isBlank()) return false
        // Relative targets are generally OK (../../bin/bash etc.)
        if (!target.startsWith("/")) return true

        // Absolute targets: only allow a very small safe set or reject
        val dangerous = listOf(
            "/system", "/vendor", "/data", "/proc", "/dev", "/sys",
            "/acct", "/mnt", "/storage", "/sdcard", "/self"
        )
        for (d in dangerous) {
            if (target == d || target.startsWith("$d/")) return false
        }
        // Anything else absolute is suspicious for bootstrap → reject
        return false
    }

    private fun createRequiredDirs() {
        listOf("tmp", "home", "var/cache", "var/log").forEach { rel ->
            File(runtimeRoot, rel).mkdirs()
        }
        listOf("tmp", "var/cache", "var/log", "home").forEach { rel ->
            File(prefixDir, rel).mkdirs()
        }
    }

    /** Write version via temp file + rename for better atomicity */
    private fun writeVersionAtomic() {
        val versionFile = File(runtimeRoot, VERSION_FILE)
        val tmp = File(runtimeRoot, "$VERSION_FILE.tmp")
        tmp.writeText(CURRENT_BOOTSTRAP_VERSION)
        if (!tmp.renameTo(versionFile)) {
            // Fallback
            versionFile.writeText(CURRENT_BOOTSTRAP_VERSION)
            tmp.delete()
        }
    }

    fun getPrefixPath(): String = prefixDir.absolutePath
    fun getRuntimeRootPath(): String = runtimeRoot.absolutePath
}
