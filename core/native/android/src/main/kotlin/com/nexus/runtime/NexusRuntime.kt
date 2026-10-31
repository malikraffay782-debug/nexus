package com.nexus.runtime

import android.content.Context

/**
 * Main entry point for the Embedded Linux Runtime.
 */
class NexusRuntime private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val bootstrapManager = BootstrapManager(appContext)
    private val executor = ProotExecutor(appContext, bootstrapManager)
    val packages = PackageManager(executor)

    companion object {
        @Volatile
        private var instance: NexusRuntime? = null

        fun getInstance(context: Context): NexusRuntime {
            return instance ?: synchronized(this) {
                instance ?: NexusRuntime(context).also { instance = it }
            }
        }
    }

    /**
     * Initialize the runtime. Safe to call multiple times.
     * @param onProgress optional callback (percent, message)
     */
    fun initialize(onProgress: ((Int, String) -> Unit)? = null): Result<Unit> {
        RuntimeLogger.i("Initializing Nexus Embedded Runtime...")
        return bootstrapManager.ensureBootstrap(onProgress)
    }

    val isReady: Boolean
        get() = bootstrapManager.isReady

    fun getPrefixPath(): String = bootstrapManager.getPrefixPath()
    fun getRuntimeRoot(): String = bootstrapManager.getRuntimeRootPath()

    fun runCommand(
        command: String,
        workingDir: String? = null,
        timeoutSec: Long = 60
    ): ProotExecutor.CommandResult {
        return executor.run(command, workingDir, timeoutSec)
    }

    /**
     * Convenience wrapper that returns only stdout on success.
     * On failure it still returns a structured result so callers stay consistent.
     */
    fun exec(command: String): ProotExecutor.CommandResult {
        return runCommand(command)
    }

    /**
     * Legacy-style helper that returns a plain string (kept for simple logging / quick checks).
     * Prefer [runCommand] or [exec] when you need proper error handling.
     */
    fun execToString(command: String): String {
        val result = runCommand(command)
        return if (result.exitCode == 0) result.stdout
        else "ERROR(${result.exitCode}): ${result.stderr}"
    }

    fun hasBinary(name: String): Boolean {
        val result = runCommand("command -v $name >/dev/null 2>&1 && echo yes || echo no")
        return result.stdout.trim() == "yes"
    }

    fun pythonVersion(): String {
        val result = runCommand("python3 --version 2>&1 || python --version 2>&1 || echo 'Python not found'")
        return if (result.exitCode == 0) result.stdout else result.stderr.ifBlank { "Python not found" }
    }

    fun uname(): String {
        val result = runCommand("uname -a")
        return if (result.exitCode == 0) result.stdout else "unknown"
    }
}