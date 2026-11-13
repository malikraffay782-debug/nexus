package com.nexus.runtime

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream

/**
 * Optional C++17 toolchain installer (clang++).
 *
 * Same pattern as [PythonInstaller]: download Termux .deb packages with the
 * Android HTTP stack (outside proot), then dpkg inside the guest.
 * Never forced — user installs on demand from Settings / Languages.
 */
class CppInstaller(
    private val context: Context,
    private val runLocked: (command: String, timeoutSec: Long) -> ProotExecutor.CommandResult
) {
    data class Result(val success: Boolean, val output: String, val error: String = "")

    companion object {
        private const val BASE = "https://packages-cf.termux.dev/apt/termux-main"
        private const val PACKAGES_GZ = "$BASE/dists/stable/main/binary-aarch64/Packages.gz"

        // clang++ / C++17 stack — dpkg resolves order; missing index entries are skipped.
        private val NEED = listOf(
            "libandroid-support",
            "libandroid-posix-semaphore",
            "libllvm",
            "compiler-rt",
            "libcompiler-rt-lite-android-21",
            "libcompiler-rt",
            "binutils",
            "binutils-bin",
            "libandroid-spawn",
            "libc++",
            "ndk-sysroot",
            "clang"
        )
    }

    private val debsDir: File
        get() = File(context.filesDir, "nexus-runtime/host-debs-cpp").also { it.mkdirs() }

    fun install(): Result {
        val log = StringBuilder()
        try {
            log.appendLine("Downloading Termux package index for C++17 (Android HTTP)...")
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
            if (filenames.none { it.contains("/clang_") }) {
                return Result(false, log.toString(), "clang package not found in Termux index")
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

            val guestDebs = File(context.filesDir, "nexus-runtime/tmp/host-debs-cpp")
            guestDebs.mkdirs()
            debsDir.listFiles()?.forEach { src ->
                if (src.name.endsWith(".deb")) {
                    src.copyTo(File(guestDebs, src.name), overwrite = true)
                }
            }

            log.appendLine("Running dpkg -i for C++17 toolchain inside proot...")
            val dpkg = runLocked(
                """
                export PATH="${'$'}PREFIX/bin:/bin:/usr/bin:${'$'}PATH"
                export LD_LIBRARY_PATH="${'$'}PREFIX/lib:/lib"
                export DEBIAN_FRONTEND=noninteractive
                set +e
                DEBS=""
                if ls /tmp/host-debs-cpp/*.deb >/dev/null 2>&1; then
                  DEBS=/tmp/host-debs-cpp/*.deb
                elif ls /tmp/nexus-debs-cpp/*.deb >/dev/null 2>&1; then
                  DEBS=/tmp/nexus-debs-cpp/*.deb
                fi
                if [ -z "${'$'}DEBS" ]; then
                  echo "no C++ deb files visible in guest" >&2
                  ls -la /tmp >&2
                  exit 1
                fi
                dpkg -i ${'$'}DEBS 2>/tmp/dpkg-cpp.err
                dpkg --configure -a 2>>/tmp/dpkg-cpp.err
                if command -v clang++ >/dev/null 2>&1; then
                  echo CPP_OK
                  clang++ --version | head -3
                  echo 'int main(){return 0;}' > /tmp/ga_cpp17_test.cpp
                  if clang++ -std=c++17 -O0 -o /tmp/ga_cpp17_test /tmp/ga_cpp17_test.cpp 2>/tmp/ga_cpp17_test.err; then
                    echo CPP17_COMPILE_OK
                  else
                    echo CPP17_COMPILE_FAIL >&2
                    cat /tmp/ga_cpp17_test.err >&2
                  fi
                  exit 0
                fi
                echo "clang++ missing after dpkg" >&2
                tail -40 /tmp/dpkg-cpp.err >&2
                exit 1
                """.trimIndent(),
                900
            )
            log.appendLine(dpkg.stdout)
            if (dpkg.stderr.isNotBlank()) log.appendLine(dpkg.stderr)

            val ok = dpkg.exitCode == 0 &&
                (dpkg.stdout.contains("CPP_OK") || dpkg.stdout.contains("clang"))
            return if (ok) {
                Result(true, log.toString(), "")
            } else {
                Result(false, log.toString(), "dpkg C++17 install failed (exit ${dpkg.exitCode})")
            }
        } catch (e: Exception) {
            RuntimeLogger.e("CppInstaller failed", e)
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
        var filename: String? = null
        for (line in index.lineSequence()) {
            when {
                line.startsWith("Package: ") -> {
                    found = line.substringAfter("Package: ").trim() == packageName
                    filename = null
                }
                found && line.startsWith("Filename: ") -> {
                    filename = line.substringAfter("Filename: ").trim()
                }
                found && line.isBlank() -> {
                    return filename
                }
            }
        }
        return filename
    }

    private fun downloadToFile(url: String, out: File) {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 30_000
            readTimeout = 180_000
            instanceFollowRedirects = true
            requestMethod = "GET"
            setRequestProperty("User-Agent", "NexusStudio/1.0")
        }
        try {
            if (conn.responseCode !in 200..299) {
                throw IllegalStateException("HTTP ${conn.responseCode} for $url")
            }
            conn.inputStream.use { input ->
                FileOutputStream(out).use { output ->
                    input.copyTo(output)
                }
            }
        } finally {
            conn.disconnect()
        }
    }
}
