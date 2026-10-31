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
        // Only allow safe package name characters
        private val SAFE_NAME = Regex("^[a-zA-Z0-9][a-zA-Z0-9+._-]*$")
    }

    private fun validateName(name: String): String? {
        if (!SAFE_NAME.matches(name)) {
            return "Invalid package name: '$name'"
        }
        return null
    }

    private fun shellQuote(s: String): String {
        // POSIX single-quote escaping
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

        for (pkg in packages) {
            validateName(pkg)?.let {
                return InstallResult(false, "", it)
            }
        }

        val quoted = packages.joinToString(" ") { shellQuote(it) }
        val cmd = """
            if command -v pkg >/dev/null 2>&1; then
                pkg install -y $quoted
            else
                apt-get install -y $quoted
            fi
        """.trimIndent()

        val result = executor.run(cmd, timeoutSec = 600)
        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }

    fun install(packageName: String): InstallResult = install(listOf(packageName))

    fun isInstalled(packageName: String): Boolean {
        if (validateName(packageName) != null) return false

        val quoted = shellQuote(packageName)
        val result = executor.run(
            """
            if command -v dpkg >/dev/null 2>&1; then
                dpkg -s $quoted 2>/dev/null | grep -q '^Status:.*installed'
            else
                pkg list-installed 2>/dev/null | grep -F $quoted >/dev/null
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
