package com.nexus.runtime

import android.content.Context
import android.os.Build
import android.system.Os
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.StringReader
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.nio.file.Paths
import java.util.concurrent.locks.ReentrantLock
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.zip.ZipInputStream
import kotlin.concurrent.withLock

/**
 * Handles first-run extraction of the Termux-style bootstrap.
 *
 * Official Termux bootstraps store symlink info in SYMLINKS.txt
 * (format: target←relativeLinkPath). We recreate them after extract.
 *
 * Symlink safety: both the link path AND the resolved target must stay
 * inside the prefix directory.
 */
class BootstrapManager(private val context: Context) {

    companion object {
        private const val RUNTIME_DIR = "nexus-runtime"
        private const val PREFIX_DIR = "prefix"
        private const val VERSION_FILE = "version"
        const val CURRENT_BOOTSTRAP_VERSION = "2026.10.1"

        private val bootstrapLock = ReentrantLock()
    }

    private val runtimeRoot: File
        get() = File(context.filesDir, RUNTIME_DIR)

    val prefixDir: File
        get() = File(runtimeRoot, PREFIX_DIR)

    val isReady: Boolean
        get() = try {
            val versionFile = File(runtimeRoot, VERSION_FILE)
            if (!versionFile.exists()) return false
            if (versionFile.readText().trim() != CURRENT_BOOTSTRAP_VERSION) return false

            val binDir = File(prefixDir, "bin")
            if (!binDir.isDirectory) return false

            val mustExist = listOf(
                File(prefixDir, "bin"),
                File(prefixDir, "etc"),
                File(prefixDir, "lib")
            )
            if (mustExist.any { !it.exists() }) return false

            val sh = File(prefixDir, "bin/sh")
            if (!sh.exists()) return false

            true
        } catch (t: Throwable) {
            RuntimeLogger.e("isReady check failed", t)
            false
        }

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

                if (prefixDir.exists()) {
                    onProgress?.invoke(15, "Cleaning old install...")
                    prefixDir.deleteRecursively()
                }
                prefixDir.mkdirs()

                extractBootstrap(arch, onProgress)
                createRequiredDirs()
                writeVersionAtomic()

                onProgress?.invoke(100, "Done")
                RuntimeLogger.i("Bootstrap extraction completed")
                Result.success(Unit)
            } catch (e: Exception) {
                RuntimeLogger.e("Bootstrap failed", e)
                // Remove partial extract so next attempt starts clean
                try {
                    if (prefixDir.exists()) prefixDir.deleteRecursively()
                    File(runtimeRoot, VERSION_FILE).delete()
                } catch (_: Exception) {}
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
        // Store: (rawTarget, linkAbsPath, linkParentAbs)
        val symlinks = mutableListOf<Triple<String, String, File>>()

        context.assets.open(assetName).use { input ->
            ZipInputStream(input).use { zis ->
                var entry = zis.nextEntry
                var count = 0
                while (entry != null) {
                    val name = entry.name

                    if (name == "SYMLINKS.txt" || name.endsWith("/SYMLINKS.txt")) {
                        // Do NOT wrap ZipInputStream in Reader.use — that closes the zip stream.
                        val baos = ByteArrayOutputStream()
                        val buf = ByteArray(8192)
                        while (true) {
                            val n = zis.read(buf)
                            if (n <= 0) break
                            baos.write(buf, 0, n)
                        }
                        BufferedReader(StringReader(baos.toString(Charsets.UTF_8.name()))).use { reader ->
                            var line = reader.readLine()
                            while (line != null) {
                                val parts = line.split("←")
                                if (parts.size == 2) {
                                    val target = parts[0].trim()
                                    val linkRel = parts[1].trim().removePrefix("./")

                                    val linkAbsFile = File(targetDir, linkRel).canonicalFile
                                    if (!linkAbsFile.toPath().startsWith(targetDir.toPath())) {
                                        RuntimeLogger.w("Skipping unsafe symlink destination: $linkRel")
                                    } else {
                                        val parent = linkAbsFile.parentFile ?: targetDir
                                        if (isResolvedTargetSafe(target, parent, targetDir)) {
                                            symlinks.add(Triple(target, linkAbsFile.absolutePath, parent))
                                        } else {
                                            RuntimeLogger.w("Skipping symlink whose resolved target escapes prefix: $target (from $linkRel)")
                                        }
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
        for ((target, linkAbs, _) in symlinks) {
            try {
                val linkFile = File(linkAbs)
                val parent = linkFile.parentFile?.canonicalFile ?: targetDir
                // Link path itself must stay under prefix (do not weaken with parent-only check)
                val resolvedLink = File(parent, linkFile.name).canonicalFile
                if (!resolvedLink.toPath().startsWith(targetDir.toPath())) {
                    RuntimeLogger.w("Refusing symlink outside prefix: $linkAbs")
                    continue
                }
                parent.mkdirs()
                if (linkFile.exists()) {
                    if (linkFile.isFile) {
                        if (!linkFile.delete()) {
                            RuntimeLogger.w("Failed to replace existing file: $linkAbs")
                            continue
                        }
                    } else {
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
     * Resolve [target] relative to [linkParent] and ensure the final
     * canonical path stays inside [prefixDir].
     *
     * This blocks both absolute host paths and relative escapes like
     * ../../../../system/bin/sh.
     */
    private fun isResolvedTargetSafe(target: String, linkParent: File, prefixDir: File): Boolean {
        if (target.isBlank()) return false

        return try {
            val resolved = if (target.startsWith("/")) {
                // Absolute target – almost never legitimate for Termux bootstrap
                File(target).canonicalFile
            } else {
                // Relative target resolved against the directory that will contain the symlink
                File(linkParent, target).canonicalFile
            }

            val prefixCanon = prefixDir.canonicalFile
            resolved.toPath().startsWith(prefixCanon.toPath())
        } catch (t: Throwable) {
            RuntimeLogger.w("Failed to resolve symlink target '$target': ${t.message}")
            false
        }
    }

    private fun createRequiredDirs() {
        listOf("tmp", "home", "var/cache", "var/log").forEach { rel ->
            File(runtimeRoot, rel).mkdirs()
        }
        listOf("tmp", "var/cache", "var/log", "home").forEach { rel ->
            File(prefixDir, rel).mkdirs()
        }
    }

    /**
     * Prefer atomic replace. If rename fails we still try, but we no longer
     * claim perfect atomicity in the fallback.
     */
    private fun writeVersionAtomic() {
        val versionFile = File(runtimeRoot, VERSION_FILE)
        val tmp = File(runtimeRoot, "$VERSION_FILE.tmp.${System.nanoTime()}")
        try {
            tmp.writeText(CURRENT_BOOTSTRAP_VERSION)
            try {
                Files.move(
                    tmp.toPath(),
                    versionFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    tmp.toPath(),
                    versionFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING
                )
            }
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    fun getPrefixPath(): String = prefixDir.absolutePath
    fun getRuntimeRootPath(): String = runtimeRoot.absolutePath
}
