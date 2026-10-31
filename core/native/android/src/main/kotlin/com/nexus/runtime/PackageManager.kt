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

    /**
     * Update package lists
     */
    fun update(): InstallResult {
        val result = executor.run("pkg update -y || apt-get update -y", timeoutSec = 120)
        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }

    /**
     * Install one or more packages
     */
    fun install(packages: List<String>): InstallResult {
        if (packages.isEmpty()) {
            return InstallResult(false, "", "No packages specified")
        }
        val pkgList = packages.joinToString(" ")
        val cmd = "pkg install -y $pkgList || apt-get install -y $pkgList"
        val result = executor.run(cmd, timeoutSec = 300)

        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }

    fun install(packageName: String): InstallResult = install(listOf(packageName))

    /**
     * Check if a package is installed (simple heuristic)
     */
    fun isInstalled(packageName: String): Boolean {
        val result = executor.run("pkg list-installed 2>/dev/null | grep -w $packageName || dpkg -l $packageName 2>/dev/null | grep -q ^ii")
        return result.exitCode == 0
    }

    /**
     * Remove a package
     */
    fun remove(packageName: String): InstallResult {
        val result = executor.run("pkg uninstall -y $packageName || apt-get remove -y $packageName")
        return InstallResult(
            success = result.exitCode == 0,
            output = result.stdout,
            error = result.stderr
        )
    }
}