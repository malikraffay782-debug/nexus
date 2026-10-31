package com.nexus.runtime

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

/**
 * Handles first-run extraction of the Termux-style bootstrap
 * into the app's private storage.
 *
 * Bootstrap zips should be placed in assets/bootstrap/ or as raw resources.
 * Naming convention: bootstrap-aarch64.zip, bootstrap-arm.zip, etc.
 */
class BootstrapManager(private val context: Context) {

    companion object {
        private const val TAG = "NexusBootstrap"
        private const val RUNTIME_DIR = "nexus-runtime"
        private const val PREFIX_DIR = "prefix"
        private const val VERSION_FILE = "version"
        private const val CURRENT_BOOTSTRAP_VERSION = "2026.10.1" // bump when bootstrap changes
    }

    private val runtimeRoot: File
        get() = File(context.filesDir, RUNTIME_DIR)

    val prefixDir: File
        get() = File(runtimeRoot, PREFIX_DIR)

    val isReady: Boolean
        get() {
            val versionFile = File(runtimeRoot, VERSION_FILE)
            return versionFile.exists() &&
                    versionFile.readText().trim() == CURRENT_BOOTSTRAP_VERSION &&
                    File(prefixDir, "bin").exists()
        }

    /**
     * Call this on app start. Returns true if runtime is ready after this call.
     */
    fun ensureBootstrap(): Result<Unit> {
        return try {
            if (isReady) {
                Log.i(TAG, "Bootstrap already ready (version $CURRENT_BOOTSTRAP_VERSION)")
                return Result.success(Unit)
            }

            Log.i(TAG, "Starting bootstrap extraction...")
            runtimeRoot.mkdirs()

            val arch = detectArch()
            Log.i(TAG, "Detected architecture: $arch")

            // Clean previous broken install
            if (prefixDir.exists()) {
                prefixDir.deleteRecursively()
            }

            extractBootstrap(arch)
            createRequiredDirs()
            writeVersion()

            Log.i(TAG, "Bootstrap extraction completed successfully")
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "Bootstrap failed", e)
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
            else -> "aarch64" // safe default for modern devices
        }
    }

    private fun extractBootstrap(arch: String) {
        val assetName = "bootstrap/bootstrap-$arch.zip"

        context.assets.open(assetName).use { input ->
            ZipInputStream(input).use { zis ->
                var entry = zis.nextEntry
                while (entry != null) {
                    val outFile = File(prefixDir, entry.name)

                    if (entry.isDirectory) {
                        outFile.mkdirs()
                    } else {
                        outFile.parentFile?.mkdirs()
                        FileOutputStream(outFile).use { fos ->
                            zis.copyTo(fos)
                        }
                        // Make binaries executable
                        if (entry.name.startsWith("bin/") ||
                            entry.name.startsWith("libexec/") ||
                            entry.name.contains("/bin/")
                        ) {
                            outFile.setExecutable(true, false)
                        }
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
        }
    }

    private fun createRequiredDirs() {
        listOf("tmp", "home", "var/cache", "var/log").forEach { rel ->
            File(runtimeRoot, rel).mkdirs()
        }
        // Also inside prefix
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