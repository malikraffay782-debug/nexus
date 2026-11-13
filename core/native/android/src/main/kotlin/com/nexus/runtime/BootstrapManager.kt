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
        const val CURRENT_BOOTSTRAP_VERSION = "2026.11.01-r1"

        private val bootstrapLock = ReentrantLock()
    }

    private val runtimeRoot: File
        get() = File(context.filesDir, RUNTIME_DIR)

    val prefixDir: File
        get() = File(runtimeRoot, PREFIX_DIR)

    /**
     * Process-lifetime cache. Once bootstrap is confirmed ready, skip repeated
     * disk checks on every isReady() call (UI polls this often).
     * Cleared only when we intentionally wipe / re-extract.
     */
    @Volatile
    private var readyCached: Boolean = false

    val isReady: Boolean
        get() {
            if (readyCached) return true
            return try {
                val structurallyReady = computeIsReady()
                val ready = structurallyReady && ensureTermuxPathLayout()
                if (ready) readyCached = true
                ready
            } catch (t: Throwable) {
                RuntimeLogger.e("isReady check failed", t)
                false
            }
        }

    private fun computeIsReady(): Boolean {
        val versionFile = File(runtimeRoot, VERSION_FILE)
        if (!versionFile.isFile) return false
        if (versionFile.readText().trim() != CURRENT_BOOTSTRAP_VERSION) return false

        val binDir = File(prefixDir, "bin")
        if (!binDir.isDirectory) return false

        // Lightweight structural checks only — no proot, no process spawn.
        if (!File(prefixDir, "etc").exists()) return false
        if (!File(prefixDir, "lib").exists()) return false
        if (!File(prefixDir, "bin/sh").exists()) return false

        return true
    }

    /**
     * Cheap filesystem probe for python after pkg install.
     * Does NOT spawn proot — safe to call on every Runtime tab open.
     */
    /**
     * Termux packages expect PREFIX at /data/data/com.termux/files/usr.
     * Under proot -r [prefixDir], create that path as a symlink to the rootfs root
     * so $PREFIX/bin resolves to /bin without a recursive -b bind (which SIGSEGVs).
     */
    /**
     * Termux packages expect PREFIX at /data/data/com.termux/files/usr.
     * Under proot -r [prefixDir], create that path as a symlink to the rootfs root.
     * @return false if the critical usr symlink could not be created.
     */
    fun ensureTermuxPathLayout(): Boolean {
        val root = prefixDir.canonicalFile
        if (!root.isDirectory) return false
        val filesDir = File(root, "data/data/com.termux/files")
        if (!filesDir.exists() && !filesDir.mkdirs()) {
            RuntimeLogger.w("Could not create Termux files dir")
            return false
        }
        // Symlink target is relative to the *parent* of the link (POSIX).
        // Link:  {prefix}/data/data/com.termux/files/usr
        // Parent: {prefix}/data/data/com.termux/files
        // ../../../../ from parent => {prefix}
        // Absolute "/" is wrong under proot (host root, not rootfs).
        val usrLink = File(filesDir, "usr")
        val expectedTarget = "../../../../"
        try {
            if (usrLink.exists() || Files.isSymbolicLink(usrLink.toPath())) {
                val current = try {
                    Files.readSymbolicLink(usrLink.toPath()).toString()
                } catch (_: Throwable) {
                    null
                }
                if (current != expectedTarget) {
                    // Wrong target (old builds used "/" or 5-level relative)
                    try { usrLink.delete() } catch (_: Throwable) {}
                    try { Files.deleteIfExists(usrLink.toPath()) } catch (_: Throwable) {}
                }
            }
            if (!Files.isSymbolicLink(usrLink.toPath())) {
                Os.symlink(expectedTarget, usrLink.absolutePath)
            }
        } catch (e: Throwable) {
            RuntimeLogger.w("Could not create Termux PREFIX symlink: ${e.message}")
            return false
        }
        // Verify host-side: resolving the symlink must land on prefix/lib
        val resolvedUsr = try {
            usrLink.canonicalFile
        } catch (_: Throwable) {
            null
        }
        if (resolvedUsr == null || resolvedUsr != root) {
            RuntimeLogger.w(
                "PREFIX symlink resolves to ${resolvedUsr?.absolutePath} expected ${root.absolutePath}"
            )
            return false
        }
        val viaLib = File(resolvedUsr, "lib")
        if (!viaLib.isDirectory) {
            RuntimeLogger.w("PREFIX/lib missing after symlink resolve")
            return false
        }
        val homeLink = File(filesDir, "home")
        if (!homeLink.exists() && !Files.isSymbolicLink(homeLink.toPath())) {
            try {
                // parent is files/; ../../../../home => {prefix}/home
                Os.symlink("../../../../home", homeLink.absolutePath)
            } catch (_: Throwable) {
                // home bind is also applied by ProotExecutor; non-fatal
            }
        }
        File(root, "tmp").mkdirs()
        File(root, "var/tmp").mkdirs()
        return true
    }

    fun hasPythonBinary(): Boolean {
        if (!isReady) return false
        val candidates = listOf(
            File(prefixDir, "bin/python3"),
            File(prefixDir, "bin/python"),
            File(prefixDir, "usr/bin/python3"),
            File(prefixDir, "usr/bin/python")
        )
        return candidates.any { f ->
            try {
                // Follow symlink targets that live inside prefix
                f.exists() && !f.isDirectory
            } catch (_: Throwable) {
                false
            }
        }
    }

    /** Filesystem-only check for optional C++17 toolchain (clang++). */
    fun hasClangBinary(): Boolean {
        if (!isReady) return false
        val candidates = listOf(
            File(prefixDir, "bin/clang++"),
            File(prefixDir, "bin/clang"),
            File(prefixDir, "usr/bin/clang++"),
            File(prefixDir, "usr/bin/clang")
        )
        return candidates.any { f ->
            try {
                f.exists() && !f.isDirectory
            } catch (_: Throwable) {
                false
            }
        }
    }

    fun invalidateReadyCache() {
        readyCached = false
    }

    fun ensureBootstrap(onProgress: ((Int, String) -> Unit)? = null): Result<Unit> {
        return bootstrapLock.withLock {
            try {
                // Force a fresh structural check; do not trust process-lifetime cache
                // across intentional re-init or after external file changes.
                readyCached = false
                if (computeIsReady() && ensureTermuxPathLayout()) {
                    readyCached = true
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
                    readyCached = false
                    prefixDir.deleteRecursively()
                }
                prefixDir.mkdirs()

                extractBootstrap(arch, onProgress)
                createRequiredDirs()
                writeVersionAtomic()

                // Re-validate structure before advertising ready (cache must not
                // hide a partial extract).
                readyCached = false
                if (!computeIsReady()) {
                    val msg = "Bootstrap extract finished but runtime is incomplete (bin/sh or dirs missing)"
                    RuntimeLogger.e(msg)
                    try {
                        if (prefixDir.exists()) prefixDir.deleteRecursively()
                        File(runtimeRoot, VERSION_FILE).delete()
                    } catch (_: Exception) {}
                    onProgress?.invoke(0, msg)
                    return@withLock Result.failure(IllegalStateException(msg))
                }
                readyCached = true

                onProgress?.invoke(100, "Done")
                RuntimeLogger.i("Bootstrap extraction completed")
                Result.success(Unit)
            } catch (e: Exception) {
                RuntimeLogger.e("Bootstrap failed", e)
                // Remove partial extract so next attempt starts clean
                try {
                    readyCached = false
                    if (prefixDir.exists()) prefixDir.deleteRecursively()
                    File(runtimeRoot, VERSION_FILE).delete()
                } catch (_: Exception) {}
                Result.failure(e)
            }
        }
    }

        private fun detectArch(): String {
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: Build.CPU_ABI
        // CI packages only aarch64 bootstrap + arm64-v8a jniLibs.
        if (abi.startsWith("arm64") || abi == "aarch64") {
            return "aarch64"
        }
        throw IllegalStateException(
            "Unsupported ABI '$abi'. This build only includes aarch64/arm64-v8a runtime."
        )
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
                        BufferedReader(StringReader(String(baos.toByteArray(), Charsets.UTF_8))).use { reader ->
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
