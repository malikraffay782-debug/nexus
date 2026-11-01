package com.nexus.runtime

/**
 * Thin wrapper around the embedded package manager.
 * All package names are validated before being passed to the shell.
 */
class PackageManager(private val executor: ProotExecutor) {

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
        val result = executor.run("pkg update -y || apt-get update -y", timeoutSec = 120)
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

        // Deduplicate while preserving order
        val seen = linkedSetOf<String>()
        val deduped = packages.filter { seen.add(it) }

        for (pkg in deduped) {
            validateName(pkg)?.let {
                return InstallResult(false, "", it)
            }
        }

        // Install in small batches to avoid E2BIG / huge command lines
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
            val result = executor.run(cmd, timeoutSec = 600)
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
        // Prefer exact match via dpkg-query; fallback to pkg with whole-line match
        val result = executor.run(
            """
            if command -v dpkg-query >/dev/null 2>&1; then
                dpkg-query -W -f='\${'$'}{Status}' $quoted 2>/dev/null | grep -Fx 'install ok installed'
            elif command -v dpkg >/dev/null 2>&1; then
                dpkg -s $quoted 2>/dev/null | grep -q '^Status:.*installed'
            else
                pkg list-installed 2>/dev/null | awk '{print \$1}' | grep -Fx $quoted
            fi
            """.trimIndent()
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

        val result = executor.run(cmd)
        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }
}
