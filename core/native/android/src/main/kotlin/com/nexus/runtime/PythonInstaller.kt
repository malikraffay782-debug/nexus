package com.nexus.runtime

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream

/**
 * Installs Termux Python by downloading .deb packages with the Android HTTP
 * stack (outside proot), then running dpkg inside the guest.
 *
 * This avoids apt's broken https method under proot (exit 100).
 */
class PythonInstaller(
    private val context: Context,
    private val runLocked: (command: String, timeoutSec: Long) -> ProotExecutor.CommandResult
) {
    data class Result(val success: Boolean, val output: String, val error: String = "")

    companion object {
        private const val BASE = "https://packages-cf.termux.dev/apt/termux-main"
        private const val PACKAGES_GZ = "$BASE/dists/stable/main/binary-aarch64/Packages.gz"

        // python Depends — download even if some libs already exist in bootstrap;
        // dpkg will unpack the rest and register the package.
        private val NEED = listOf(
            "libandroid-support",
            "libandroid-posix-semaphore",
            "libbz2",
            "libcrypt",
            "libexpat",
            "libffi",
            "liblzma",
            "libsqlite",
            "ncurses",
            "ncurses-ui-libs",
            "openssl",
            "readline",
            "gdbm",
            "zlib",
            "zstd",
            "python"
        )
    }

    private val debsDir: File
        get() = File(context.filesDir, "nexus-runtime/host-debs").also { it.mkdirs() }

    fun install(): Result {
        val log = StringBuilder()
        try {
            log.appendLine("Downloading Termux package index (Android HTTP)...")
            val indexText = downloadPackagesIndex()
            log.appendLine("Index size=${indexText.length}")

            val filenames = mutableListOf<String>()
            for (pkg in NEED) {
                val fn = findFilename(indexText, pkg)
                if (fn == null) {
                    log.appendLine("skip $pkg (not in index)")
                    continue
                }
                filenames.add(fn)
            }
            if (filenames.none { it.contains("/python_") }) {
                return Result(false, log.toString(), "python package not found in Termux index")
            }

            for (fn in filenames) {
                val name = fn.substringAfterLast('/')
                val out = File(debsDir, name)
                if (out.isFile && out.length() > 1000) {
                    log.appendLine("cached $name (${out.length()} bytes)")
                    continue
                }
                log.appendLine("GET $fn")
                downloadToFile("$BASE/$fn", out)
                log.appendLine("saved $name (${out.length()} bytes)")
            }

            val hostDebs = debsDir.absolutePath
            // dpkg inside guest; bind is not needed if we copy into prefix-visible path
            // under the already-bound runtime root.
            val guestDebs = File(context.filesDir, "nexus-runtime/tmp/host-debs")
            guestDebs.mkdirs()
            // Copy debs into runtime tmp which is bound as /tmp in proot
            debsDir.listFiles()?.forEach { src ->
                if (src.name.endsWith(".deb")) {
                    src.copyTo(File(guestDebs, src.name), overwrite = true)
                }
            }

            log.appendLine("Running dpkg -i inside proot...")
            val dpkg = runLocked(
                """
                export PATH="${'$'}PREFIX/bin:/bin:/usr/bin:${'$'}PATH"
                export LD_LIBRARY_PATH="${'$'}PREFIX/lib:/lib"
                export DEBIAN_FRONTEND=noninteractive
                set +e
                ls -la /tmp/host-debs/*.deb 2>/dev/null || ls -la /tmp/nexus-debs/*.deb 2>/dev/null
                # Prefer copied path under bound /tmp
                DEBS=""
                if ls /tmp/host-debs/*.deb >/dev/null 2>&1; then
                  DEBS=/tmp/host-debs/*.deb
                elif ls /tmp/nexus-debs/*.deb >/dev/null 2>&1; then
                  DEBS=/tmp/nexus-debs/*.deb
                fi
                if [ -z "${'$'}DEBS" ]; then
                  echo "no deb files visible in guest" >&2
                  ls -la /tmp >&2
                  exit 1
                fi
                dpkg -i ${'$'}DEBS 2>/tmp/dpkg.err
                dpkg --configure -a 2>>/tmp/dpkg.err
                if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
                  echo PYTHON_OK
                  python3 --version 2>/dev/null || python --version
                  exit 0
                fi
                echo "python missing after dpkg" >&2
                tail -40 /tmp/dpkg.err >&2
                exit 1
                """.trimIndent(),
                600
            )
            log.appendLine(dpkg.stdout)
            if (dpkg.stderr.isNotBlank()) log.appendLine(dpkg.stderr)

            val ok = dpkg.exitCode == 0 &&
                (dpkg.stdout.contains("PYTHON_OK") || dpkg.stdout.contains("Python"))
            return if (ok) {
                Result(true, log.toString(), "")
            } else {
                Result(false, log.toString(), "dpkg python install failed (exit ${dpkg.exitCode})")
            }
        } catch (e: Exception) {
            RuntimeLogger.e("PythonInstaller failed", e)
            return Result(false, log.toString(), e.message ?: "download/install error")
        }
    }

    private fun downloadPackagesIndex(): String {
        val conn = (URL(PACKAGES_GZ).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000
            readTimeout = 60_000
            instanceFollowRedirects = true
            requestMethod = "GET"
            setRequestProperty("User-Agent", "NexusStudio/1.0")
        }
        try {
            if (conn.responseCode !in 200..299) {
                throw IllegalStateException("Packages.gz HTTP ${conn.responseCode}")
            }
            return GZIPInputStream(conn.inputStream).bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    private fun findFilename(index: String, packageName: String): String? {
        var found = false
        for (line in index.lineSequence()) {
            when {
                line.startsWith("Package: ") -> {
                    found = line.substringAfter("Package: ").trim() == packageName
                }
                found && line.startsWith("Filename: ") -> {
                    return line.substringAfter("Filename: ").trim()
                }
            }
        }
        return null
    }

    private fun downloadToFile(url: String, dest: File) {
        val tmp = File(dest.absolutePath + ".partial")
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000
            readTimeout = 120_000
            instanceFollowRedirects = true
            requestMethod = "GET"
            setRequestProperty("User-Agent", "NexusStudio/1.0")
        }
        try {
            if (conn.responseCode !in 200..299) {
                throw IllegalStateException("HTTP ${conn.responseCode} for $url")
            }
            conn.inputStream.use { input ->
                FileOutputStream(tmp).use { output ->
                    input.copyTo(output)
                }
            }
            if (!tmp.renameTo(dest)) {
                tmp.copyTo(dest, overwrite = true)
                tmp.delete()
            }
        } finally {
            conn.disconnect()
            if (tmp.exists() && !dest.exists()) tmp.delete()
        }
    }
}
