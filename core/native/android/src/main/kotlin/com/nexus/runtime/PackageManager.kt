package com.nexus.runtime

/**
 * Very thin wrapper around the embedded package manager.
 * Right now it just runs the underlying pkg/apt commands.
 * Later we can add caching, progress parsing, and offline support.
 */
class PackageManager(private val executor: ProotExecutor) {

    data class InstallResult(
        val success: Boolean,
        val output: String,
        val error: String = ""
    )

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
        val pkgList = packages.joinToString(" ")
        val cmd = "pkg install -y $pkgList || apt-get install -y $pkgList"
        val result = executor.run(cmd, timeoutSec = 600) // larger packages need more time

        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }

    fun install(packageName: String): InstallResult = install(listOf(packageName))

    /**
     * More reliable check than simple grep.
     */
    fun isInstalled(packageName: String): Boolean {
        // Prefer dpkg when available (more accurate), fallback to pkg
        val result = executor.run(
            """
            if command -v dpkg >/dev/null 2>&1; then
                dpkg -s "$packageName" 2>/dev/null | grep -q '^Status:.*installed'
            else
                pkg list-installed 2>/dev/null | grep -E "^$packageName(/| )" >/dev/null
            fi
            """.trimIndent()
        )
        return result.exitCode == 0
    }

    fun remove(packageName: String): InstallResult {
        val result = executor.run("pkg uninstall -y $packageName || apt-get remove -y $packageName")
        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }
}