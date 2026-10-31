package com.nexus.runtime

import android.content.Context
import android.os.Build
import android.system.Os
import java.io.BufferedReader
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.util.zip.ZipInputStream

/**
 * Handles first-run extraction of the Termux-style bootstrap
 * into the app's private storage.
 *
 * Official Termux bootstraps do NOT store real symlinks inside the zip.
 * Instead they ship a SYMLINKS.txt file (format: target←relativeLinkPath).
 * After extracting regular files we recreate every symlink from that list.
 * This is exactly how termux-app itself installs the bootstrap.
 */
class BootstrapManager(private val context: Context) {

    companion object {
        private const val RUNTIME_DIR = "nexus-runtime"
        private const val PREFIX_DIR = "prefix"
        private const val VERSION_FILE = "version"
        const val CURRENT_BOOTSTRAP_VERSION = "2026.10.1"
    }

    private val runtimeRoot: File
        get() = File(context.filesDir, RUNTIME_DIR)

    val prefixDir: File
        get() = File(runtimeRoot, PREFIX_DIR)

    val isReady: Boolean
        get() = try {
            val versionFile = File(runtimeRoot, VERSION_FILE)
            versionFile.exists() &&
                versionFile.readText().trim() == CURRENT_BOOTSTRAP_VERSION &&
                File(prefixDir, "bin").exists()
        } catch (t: Throwable) {
            RuntimeLogger.e("isReady check failed", t)
            false
        }

    /**
     * Progress callback: (percent 0-100, message)
     */
    fun ensureBootstrap(onProgress: ((Int, String) -> Unit)? = null): Result<Unit> {
        return try {
            if (isReady) {
                RuntimeLogger.i("Bootstrap already ready (v$CURRENT_BOOTSTRAP_VERSION)")
                onProgress?.invoke(100, "Already ready")
                return Result.success(Unit)
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
                val msg = "Bootstrap asset not found: $assetName. " +
                        "Place the correct bootstrap zip in assets/bootstrap/"
                RuntimeLogger.e(msg)
                onProgress?.invoke(0, msg)
                return Result.failure(FileNotFoundException(msg))
            }

            if (prefixDir.exists()) {
                onProgress?.invoke(15, "Cleaning old install...")
                // Best-effort clean. If it partially fails we still try a fresh extract.
                prefixDir.deleteRecursively()
            }
            prefixDir.mkdirs()

            extractBootstrap(arch, onProgress)
            createRequiredDirs()
            writeVersion()

            onProgress?.invoke(100, "Done")
            RuntimeLogger.i("Bootstrap extraction completed")
            Result.success(Unit)
        } catch (e: Exception) {
            RuntimeLogger.e("Bootstrap failed", e)
            Result.failure(e)
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
        // Collect symlink definitions: Pair(target, linkAbsolutePath)
        val symlinks = mutableListOf<Pair<String, String>>()

        context.assets.open(assetName).use { input ->
            ZipInputStream(input).use { zis ->
                var entry = zis.nextEntry
                var count = 0
                while (entry != null) {
                    val name = entry.name

                    // --- Official Termux approach: collect SYMLINKS.txt ---
                    if (name == "SYMLINKS.txt" || name.endsWith("/SYMLINKS.txt")) {
                        BufferedReader(InputStreamReader(zis)).use { reader ->
                            var line = reader.readLine()
                            while (line != null) {
                                val parts = line.split("←")
                                if (parts.size == 2) {
                                    val target = parts[0]
                                    val linkRel = parts[1].removePrefix("./")
                                    val linkAbs = File(targetDir, linkRel).canonicalPath
                                    // Zip-slip guard on the link destination
                                    if (linkAbs.startsWith(targetDir.path)) {
                                        symlinks.add(target to linkAbs)
                                    } else {
                                        RuntimeLogger.w("Skipping unsafe symlink destination: $linkRel")
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

                    // --- Zip Slip protection for regular entries ---
                    val outFile = File(targetDir, name).canonicalFile
                    if (!outFile.toPath().startsWith(targetDir.toPath())) {
                        throw SecurityException("Zip Slip blocked: entry '$name' resolves outside target directory")
                    }

                    if (entry.isDirectory) {
                        outFile.mkdirs()
                    } else {
                        outFile.parentFile?.mkdirs()
                        FileOutputStream(outFile).use { fos ->
                            zis.copyTo(fos)
                        }
                        // Best-effort executable bit for common binary locations
                        if (name.startsWith("bin/") ||
                            name.startsWith("libexec/") ||
                            name.contains("/bin/")
                        ) {
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

        // --- Recreate all symlinks (the critical part that was missing) ---
        onProgress?.invoke(88, "Creating ${symlinks.size} symlinks...")
        RuntimeLogger.i("Creating ${symlinks.size} symlinks from SYMLINKS.txt")

        var created = 0
        for ((target, linkAbs) in symlinks) {
            try {
                val linkFile = File(linkAbs)
                linkFile.parentFile?.mkdirs()
                // Remove any regular file that was incorrectly extracted in place of the link
                if (linkFile.exists()) {
                    linkFile.delete()
                }
                // Use Android's Os.symlink (same as official TermuxInstaller)
                Os.symlink(target, linkAbs)
                created++
            } catch (t: Throwable) {
                RuntimeLogger.w("Failed to create symlink $linkAbs -> $target : ${t.message}")
            }
        }
        RuntimeLogger.i("Created $created / ${symlinks.size} symlinks")

        // Ensure critical bin directory is executable
        File(targetDir, "bin").setExecutable(true, false)
        onProgress?.invoke(95, "Symlinks ready")
    }

    private fun createRequiredDirs() {
        listOf("tmp", "home", "var/cache", "var/log").forEach { rel ->
            File(runtimeRoot, rel).mkdirs()
        }
        listOf("tmp", "var/cache", "var/log", "home").forEach { rel ->
            File(prefixDir, rel).mkdirs()
        }
    }

    private fun writeVersion() {
        File(runtimeRoot, VERSION_FILE).writeText(CURRENT_BOOTSTRAP_VERSION)
    }

    fun getPrefixPath(): String = prefixDir.absolutePath
    fun getRuntimeRootPath(): String = runtimeRoot.absolutePath
}
