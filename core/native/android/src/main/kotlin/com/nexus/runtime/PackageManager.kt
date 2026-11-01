package com.nexus.runtime

/**
 * Thin wrapper around the embedded package manager.
 * Executes via [runLocked] so install/update cannot race with bootstrap re-init.
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

    private fun validateName(name: String): String? {
        if (!SAFE_NAME.matches(name)) {
            return "Invalid package name: '$name'"
        }
        return null
    }

    private fun shellQuote(s: String): String {
        return "'" + s.replace("'", "'\\''") + "'"
    }

    fun update(): InstallResult {
        val result = runLocked("pkg update -y || apt-get update -y", 120)
        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }

    fun install(packages: List<String>): InstallResult {
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

        val batchSize = 8
        val outputs = StringBuilder()
        for (batch in deduped.chunked(batchSize)) {
            val quoted = batch.joinToString(" ") { shellQuote(it) }
            val cmd = """
                if command -v pkg >/dev/null 2>&1; then
                    pkg install -y $quoted
                else
                    apt-get install -y $quoted
                fi
            """.trimIndent()
            val result = runLocked(cmd, 600)
            if (result.stdout.isNotBlank()) outputs.append(result.stdout).append('\n')
            if (result.exitCode != 0) {
                return InstallResult(
                    success = false,
                    output = outputs.toString(),
                    error = result.stderr.ifBlank { "Install failed in batch: ${batch.joinToString()}" }
                )
            }
        }
        return InstallResult(true, outputs.toString(), "")
    }

    fun install(packageName: String): InstallResult = install(listOf(packageName))

    fun isInstalled(packageName: String): Boolean {
        if (validateName(packageName) != null) return false

        val quoted = shellQuote(packageName)
        // dpkg-query format: ${Status} must reach the shell, not Kotlin
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
        return result.exitCode == 0
    }

    fun remove(packageName: String): InstallResult {
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
