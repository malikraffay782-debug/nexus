package com.nexus.runtime

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Thin wrapper around the embedded package manager.
 * Executes via [runLocked] so install/update cannot race with bootstrap re-init.
 * Package mutations are mutually exclusive (separate from the runtime read lock).
 */
class PackageManager(
    private val runLocked: (command: String, timeoutSec: Long) -> ProotExecutor.CommandResult,
    private val pythonInstaller: PythonInstaller? = null
) {

    data class InstallResult(
        val success: Boolean,
        val output: String,
        val error: String = ""
    )

    companion object {
        private val SAFE_NAME = Regex("^[a-zA-Z0-9][a-zA-Z0-9+._-]*$")
    }

    private val packageMutex = ReentrantLock()

    private fun validateName(name: String): String? {
        if (!SAFE_NAME.matches(name)) {
            return "Invalid package name: '$name'"
        }
        return null
    }

    private fun shellQuote(s: String): String {
        return "'" + s.replace("'", "'\\''") + "'"
    }

    fun update(): InstallResult = packageMutex.withLock {
        val result = runLocked("pkg update -y || apt-get update -y", 120)
        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }

    fun install(packages: List<String>): InstallResult = packageMutex.withLock {
        if (packages.isEmpty()) {
            return InstallResult(false, "", "No packages specified")
        }

        val seen = linkedSetOf<String>()
        val deduped = packages.filter { seen.add(it) }

        for (pkg in deduped) {
            validateName(pkg)?.let {
                return InstallResult(false, "", it)
            }
        }

        val outputs = StringBuilder()

        fun appendResult(label: String, result: ProotExecutor.CommandResult) {
            outputs.append("—— ").append(label).append(" ——\n")
            if (result.stdout.isNotBlank()) outputs.append(result.stdout).append('\n')
            if (result.stderr.isNotBlank()) outputs.append(result.stderr).append('\n')
            if (result.timedOut) outputs.append("[timed out]\n")
        }

        // Prove proot+shell works before touching apt.
        // Termux /bin/sh is dash with INTERP=/system/bin/linker64 — needs /system bind.
        val probeTrue = runLocked("/bin/true", 20)
        val probe = if (probeTrue.exitCode == 0) {
            val echo = runLocked("echo NEXUS_OK", 20)
            if (echo.exitCode == 0 && echo.stdout.contains("NEXUS_OK")) echo else probeTrue.copy(
                stdout = (probeTrue.stdout + "\n" + echo.stdout).trim(),
                stderr = (probeTrue.stderr + "\n" + echo.stderr).trim()
            )
        } else {
            runLocked("echo NEXUS_OK", 30)
        }
        appendResult("runtime probe", probe)
        val probeOk = probe.exitCode == 0 && (
            probe.stdout.contains("NEXUS_OK") || probeTrue.exitCode == 0
        )
        if (!probeOk) {
            val detail = listOf(probe.stdout, probe.stderr, probeTrue.stderr)
                .filter { it.isNotBlank() }
                .joinToString("\n")
                .ifBlank { "runtime probe failed (exit ${probe.exitCode})" }
            return InstallResult(
                success = false,
                output = outputs.toString(),
                error = detail +
                    "\n\nHint: Permission denied (error=13) = W^X (binary not in nativeLibraryDir). " +
                    "SIGSEGV (139) = proot crash on this device/kernel. " +
                    "Uninstall old APK, install latest build, then Initialize again."
            )
        }

        // Prefer HTTP mirror first (apt "https" method is the same binary as
        // "http" but SSL init often exits 100 under proot). Fall back to HTTPS CDN.
        val update = runLocked(
            """
            export DEBIAN_FRONTEND=noninteractive
            export PATH="${'$'}PREFIX/bin:/bin:/usr/bin:${'$'}PATH"
            export LD_LIBRARY_PATH="${'$'}PREFIX/lib:/lib${'$'}{LD_LIBRARY_PATH:+:${'$'}LD_LIBRARY_PATH}"
            export SSL_CERT_FILE="${'$'}PREFIX/etc/tls/cert.pem"
            export CURL_CA_BUNDLE="${'$'}PREFIX/etc/tls/cert.pem"
            mkdir -p "${'$'}PREFIX/etc/apt/apt.conf.d" "${'$'}PREFIX/var/lib/apt/lists/partial" /tmp/nexus-debs
            rm -f "${'$'}PREFIX/etc/apt/sources.list.d/"*.list 2>/dev/null || true

            # Quick diagnostic: can we load the apt method binary at all?
            METH="${'$'}PREFIX/lib/apt/methods/http"
            if [ ! -e "${'$'}METH" ]; then METH=/lib/apt/methods/http; fi
            if [ -e "${'$'}METH" ]; then
              echo "apt method: ${'$'}METH"
              # method speaks a protocol on stdin; closing stdin should exit cleanly
              timeout 3 "${'$'}METH" </dev/null 2>/tmp/nexus-meth.err || true
              if [ -s /tmp/nexus-meth.err ]; then
                echo "method stderr:" >&2
                head -c 500 /tmp/nexus-meth.err >&2 || true
              fi
            fi

            try_update() {
              local src="${'$'}1"
              echo "Using sources: ${'$'}src"
              printf '%s\n' "${'$'}src" > "${'$'}PREFIX/etc/apt/sources.list"
              apt-get update -y
            }

            if ! command -v apt-get >/dev/null 2>&1; then
              echo "apt-get not found PATH=${'$'}PATH PREFIX=${'$'}PREFIX" >&2
              exit 127
            fi

            # 1) HTTP mirror (no TLS)
            if try_update "deb http://mirror.mephi.ru/termux/termux-main stable main"; then
              exit 0
            fi
            # 2) Official HTTPS CDN
            if try_update "deb https://packages-cf.termux.dev/apt/termux-main stable main"; then
              exit 0
            fi
            # 3) packages.termux.dev
            if try_update "deb https://packages.termux.dev/apt/termux-main stable main"; then
              exit 0
            fi
            echo "All apt-get update attempts failed" >&2
            exit 1
            """.trimIndent(),
            300
        )
        appendResult("pkg update", update)
        if (update.exitCode != 0) {
            val wantsPython = deduped.any { it == "python" || it == "python3" }
            if (wantsPython) {
                // Prefer Android HTTP download + dpkg (apt https dies under proot).
                val host = pythonInstaller?.install()
                if (host != null) {
                    appendResult("host python install", ProotExecutor.CommandResult(
                        if (host.success) 0 else 1,
                        host.output,
                        host.error,
                        false
                    ))
                    if (host.success) {
                        return InstallResult(true, outputs.toString(), "")
                    }
                    outputs.append(host.output).append('\n')
                    if (host.error.isNotBlank()) outputs.append(host.error).append('\n')
                }
                // Last resort: guest curl (often fails for same SSL reason)
                val offline = runLocked(offlinePythonScript(), 600)
                appendResult("offline python install", offline)
                if (offline.exitCode == 0 &&
                    (offline.stdout.contains("PYTHON_OK") || offline.stdout.contains("Python"))
                ) {
                    return InstallResult(true, outputs.toString(), "")
                }
                if (offline.stdout.isNotBlank()) outputs.append(offline.stdout).append('\n')
                if (offline.stderr.isNotBlank()) outputs.append(offline.stderr).append('\n')
            }
            val detail = listOf(update.stdout, update.stderr)
                .filter { it.isNotBlank() }
                .joinToString("\n")
                .ifBlank { "pkg update failed (exit ${update.exitCode})" }
            val hint = "\n\nHint: apt https broken under proot. Host-side deb download was tried for python."
            return InstallResult(
                success = false,
                output = outputs.toString(),
                error = detail + hint
            )
        }

        val batchSize = 8
        for (batch in deduped.chunked(batchSize)) {
            val quoted = batch.joinToString(" ") { shellQuote(it) }
            val cmd = """
                export DEBIAN_FRONTEND=noninteractive
                export PATH="${'$'}PREFIX/bin:/bin:/usr/bin:${'$'}PATH"
                export LD_LIBRARY_PATH="${'$'}PREFIX/lib${'$'}{LD_LIBRARY_PATH:+:${'$'}LD_LIBRARY_PATH}"
                export SSL_CERT_FILE="${'$'}PREFIX/etc/tls/cert.pem"
                export CURL_CA_BUNDLE="${'$'}PREFIX/etc/tls/cert.pem"
                if command -v apt-get >/dev/null 2>&1; then
                  apt-get install -y --allow-downgrades $quoted
                elif command -v pkg >/dev/null 2>&1; then
                  pkg install -y $quoted
                else
                  echo "Neither apt-get nor pkg found" >&2
                  exit 127
                fi
            """.trimIndent()
            val result = runLocked(cmd, 600)
            appendResult("pkg install ${batch.joinToString()}", result)
            if (result.exitCode != 0) {
                val detail = listOf(result.stdout, result.stderr)
                    .filter { it.isNotBlank() }
                    .joinToString("\n")
                    .ifBlank { "Install failed for: ${batch.joinToString()}" }
                return InstallResult(
                    success = false,
                    output = outputs.toString(),
                    error = detail
                )
            }
        }
        return InstallResult(true, outputs.toString(), "")
    }

    fun install(packageName: String): InstallResult = install(listOf(packageName))


    private fun offlinePythonScript(): String {
        return """
            export PATH="${'$'}PREFIX/bin:/bin:/usr/bin:${'$'}PATH"
            export LD_LIBRARY_PATH="${'$'}PREFIX/lib:/lib"
            export SSL_CERT_FILE="${'$'}PREFIX/etc/tls/cert.pem"
            export CURL_CA_BUNDLE="${'$'}PREFIX/etc/tls/cert.pem"
            set -e
            mkdir -p /tmp/nexus-debs
            cd /tmp/nexus-debs
            BASE="https://packages-cf.termux.dev/apt/termux-main"
            echo "Fetching Packages index via curl..."
            curl -fsSL "${'$'}BASE/dists/stable/main/binary-aarch64/Packages.gz" -o Packages.gz
            gzip -dc Packages.gz > Packages
            NEED="python libandroid-posix-semaphore libandroid-support libbz2 libcrypt libexpat libffi liblzma libsqlite ncurses ncurses-ui-libs openssl readline gdbm zstd"
            for p in ${'$'}NEED; do
              fn=${'$'}(awk -v pkg="${'$'}p" '
                ${'$'}1=="Package:" && ${'$'}2==pkg {found=1}
                found && ${'$'}1=="Filename:" {print ${'$'}2; exit}
                found && ${'$'}1=="Package:" {exit}
              ' Packages)
              if [ -z "${'$'}fn" ]; then
                echo "skip ${'$'}p (no Filename)"
                continue
              fi
              echo "Downloading ${'$'}fn"
              curl -fsSL "${'$'}BASE/${'$'}fn" -o "$(basename "${'$'}fn")" || {
                echo "download failed: ${'$'}fn" >&2
                exit 1
              }
            done
            echo "Installing debs..."
            dpkg -i /tmp/nexus-debs/*.deb 2>/tmp/dpkg.err || true
            dpkg --configure -a 2>>/tmp/dpkg.err || true
            if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
              echo "PYTHON_OK"
              python3 --version 2>/dev/null || python --version
              exit 0
            fi
            echo "python missing after offline install" >&2
            tail -30 /tmp/dpkg.err 2>/dev/null >&2 || true
            exit 1
        """.trimIndent()
    }

    fun isInstalled(packageName: String): Boolean {
        if (validateName(packageName) != null) return false
        // Read-only queries need not hold the mutation mutex long-term,
        // but avoid racing mid-install by taking it briefly.
        return packageMutex.withLock {
            val quoted = shellQuote(packageName)
            val result = runLocked(
                """
                if command -v dpkg-query >/dev/null 2>&1; then
                    dpkg-query -W -f='${'$'}{Status}\n' $quoted 2>/dev/null | grep -Fx 'install ok installed'
                elif command -v dpkg >/dev/null 2>&1; then
                    dpkg -s $quoted 2>/dev/null | grep -q '^Status:.*installed'
                else
                    pkg list-installed 2>/dev/null | awk '{print $$1}' | grep -Fx $quoted
                fi
                """.trimIndent(),
                60
            )
            result.exitCode == 0
        }
    }

    fun remove(packageName: String): InstallResult = packageMutex.withLock {
        validateName(packageName)?.let {
            return InstallResult(false, "", it)
        }

        val quoted = shellQuote(packageName)
        val cmd = """
            if command -v pkg >/dev/null 2>&1; then
                pkg uninstall -y $quoted
            else
                apt-get remove -y $quoted
            fi
        """.trimIndent()

        val result = runLocked(cmd, 120)
        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }
}
