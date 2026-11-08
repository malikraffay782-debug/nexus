package com.nexus.runtime

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Thin wrapper around the embedded package manager.
 * Executes via [runLocked] so install/update cannot race with bootstrap re-init.
 * Package mutations are mutually exclusive (separate from the runtime read lock).
 */
class PackageManager(
    private val runLocked: (command: String, timeoutSec: Long) -> ProotExecutor.CommandResult
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

        // Pin a known-good mirror and use apt-get only. `pkg update` runs
        // termux-change-repo which picks random mirrors and still needs the
        // apt https method — if that method cannot load libcurl, it dies with
        // exit 100. Fixed sources + LD_LIBRARY_PATH (set by ProotExecutor) fix it.
        val update = runLocked(
            """
            export DEBIAN_FRONTEND=noninteractive
            export PATH="${'$'}PREFIX/bin:/bin:/usr/bin:${'$'}PATH"
            export LD_LIBRARY_PATH="${'$'}PREFIX/lib${'$'}{LD_LIBRARY_PATH:+:${'$'}LD_LIBRARY_PATH}"
            export SSL_CERT_FILE="${'$'}PREFIX/etc/tls/cert.pem"
            export CURL_CA_BUNDLE="${'$'}PREFIX/etc/tls/cert.pem"
            mkdir -p "${'$'}PREFIX/etc/apt/apt.conf.d" "${'$'}PREFIX/var/lib/apt/lists/partial"
            # Force official Termux CDN — skip mirror auto-selection
            cat > "${'$'}PREFIX/etc/apt/sources.list" << 'SRC'
deb https://packages-cf.termux.dev/apt/termux-main stable main
SRC
            rm -f "${'$'}PREFIX/etc/apt/sources.list.d/"*.list 2>/dev/null || true
            if ! command -v apt-get >/dev/null 2>&1; then
              echo "apt-get not found in PATH=${'$'}PATH PREFIX=${'$'}PREFIX" >&2
              exit 127
            fi
            # Sanity: https method must exist (symlink to http)
            if [ ! -e "${'$'}PREFIX/lib/apt/methods/https" ] && [ ! -e /lib/apt/methods/https ]; then
              echo "apt https method missing under PREFIX" >&2
              ls -la "${'$'}PREFIX/lib/apt/methods/" 2>&1 || true
              exit 127
            fi
            apt-get update -y
            """.trimIndent(),
            240
        )
        appendResult("pkg update", update)
        if (update.exitCode != 0) {
            val detail = listOf(update.stdout, update.stderr)
                .filter { it.isNotBlank() }
                .joinToString("\n")
                .ifBlank { "pkg update failed (exit ${update.exitCode})" }
            val hint = when (update.exitCode) {
                139, -11 -> "\n\nHint: exit 139 = crash (SIGSEGV) in proot/pkg. Not a network error."
                else -> "\n\nHint: apt https method exit 100 usually means Termux PREFIX symlink or LD_LIBRARY_PATH is wrong. Re-Initialize after updating the app. Check network if mirrors fail."
            }
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
