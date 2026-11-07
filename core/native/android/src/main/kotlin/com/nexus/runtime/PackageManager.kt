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

        // Refresh indexes first — without this, pkg install often fails on fresh bootstrap.
        val update = runLocked(
            """
            set -e
            export DEBIAN_FRONTEND=noninteractive
            if command -v pkg >/dev/null 2>&1; then
              pkg update -y
            else
              apt-get update -y
            fi
            """.trimIndent(),
            180
        )
        appendResult("pkg update", update)
        if (update.exitCode != 0) {
            val detail = listOf(update.stdout, update.stderr)
                .filter { it.isNotBlank() }
                .joinToString("\n")
                .ifBlank { "pkg update failed (exit ${update.exitCode})" }
            return InstallResult(
                success = false,
                output = outputs.toString(),
                error = detail +
                    "\n\nHint: device needs network access so the runtime can reach packages.termux.dev"
            )
        }

        val batchSize = 8
        for (batch in deduped.chunked(batchSize)) {
            val quoted = batch.joinToString(" ") { shellQuote(it) }
            val cmd = """
                set -e
                export DEBIAN_FRONTEND=noninteractive
                if command -v pkg >/dev/null 2>&1; then
                  pkg install -y $quoted
                else
                  apt-get install -y $quoted
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
