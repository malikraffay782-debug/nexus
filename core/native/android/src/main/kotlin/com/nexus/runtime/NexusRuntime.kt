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

    fun exec(command: String): String {
        val result = runCommand(command)
        return if (result.exitCode == 0) result.stdout
        else "ERROR(${result.exitCode}): ${result.stderr}"
    }

    fun hasBinary(name: String): Boolean {
        val result = runCommand("command -v $name >/dev/null 2>&1 && echo yes || echo no")
        return result.stdout.trim() == "yes"
    }

    fun pythonVersion(): String {
        return exec("python3 --version 2>&1 || python --version 2>&1 || echo 'Python not found'")
    }

    fun uname(): String = exec("uname -a")
}