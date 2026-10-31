package com.nexus.runtime

import android.content.Context
import android.os.Build
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

/**
 * Handles first-run extraction of the Termux-style bootstrap
 * into the app's private storage.
 *
 * Bootstrap zips should be placed in assets/bootstrap/
 * Naming: bootstrap-aarch64.zip, bootstrap-arm.zip, etc.
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

            // Clear error if asset is missing
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
                prefixDir.deleteRecursively()
            }

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

        context.assets.open(assetName).use { input ->
            ZipInputStream(input).use { zis ->
                var entry = zis.nextEntry
                var count = 0
                while (entry != null) {
                    count++

                    // --- Zip Slip protection ---
                    val outFile = File(targetDir, entry.name).canonicalFile
                    if (!outFile.toPath().startsWith(targetDir.toPath())) {
                        throw SecurityException("Zip Slip blocked: entry '${entry.name}' resolves outside target directory")
                    }

                    if (entry.isDirectory) {
                        outFile.mkdirs()
                    } else {
                        outFile.parentFile?.mkdirs()
                        FileOutputStream(outFile).use { fos ->
                            zis.copyTo(fos)
                        }
                        // Best-effort executable bit for common binary locations
                        if (entry.name.startsWith("bin/") ||
                            entry.name.startsWith("libexec/") ||
                            entry.name.contains("/bin/")
                        ) {
                            outFile.setExecutable(true, false)
                        }
                    }

                    // Approximate progress
                    if (count % 25 == 0) {
                        val fakePercent = (20 + (count.coerceAtMost(400) * 70 / 400)).coerceAtMost(90)
                        onProgress?.invoke(fakePercent, "Extracting... ($count files)")
                    }

                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
        }
        onProgress?.invoke(92, "Finishing...")
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