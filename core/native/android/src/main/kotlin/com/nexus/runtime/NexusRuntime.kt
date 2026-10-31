package com.nexus.runtime

import android.content.Context
import android.util.Log

/**
 * Main entry point for the Embedded Linux Runtime.
 * Use this class from Flutter via MethodChannel or from other native code.
 */
class NexusRuntime private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val bootstrapManager = BootstrapManager(appContext)
    private val executor = ProotExecutor(appContext, bootstrapManager)

    companion object {
        private const val TAG = "NexusRuntime"
        @Volatile
        private var instance: NexusRuntime? = null

        fun getInstance(context: Context): NexusRuntime {
            return instance ?: synchronized(this) {
                instance ?: NexusRuntime(context).also { instance = it }
            }
        }
    }

    /**
     * Must be called once (preferably on background thread) before using the runtime.
     */
    fun initialize(): Result<Unit> {
        Log.i(TAG, "Initializing Nexus Embedded Runtime...")
        return bootstrapManager.ensureBootstrap()
    }

    val isReady: Boolean
        get() = bootstrapManager.isReady

    fun getPrefixPath(): String = bootstrapManager.getPrefixPath()

    fun getRuntimeRoot(): String = bootstrapManager.getRuntimeRootPath()

    /**
     * Run a shell command inside the embedded environment.
     */
    fun runCommand(
        command: String,
        workingDir: String? = null,
        timeoutSec: Long = 60
    ): ProotExecutor.CommandResult {
        return executor.run(command, workingDir, timeoutSec)
    }

    /**
     * Quick helper for simple commands.
     */
    fun exec(command: String): String {
        val result = runCommand(command)
        return if (result.exitCode == 0) {
            result.stdout
        } else {
            "ERROR(${result.exitCode}): ${result.stderr}"
        }
    }

    /**
     * Check if a binary exists inside the prefix.
     */
    fun hasBinary(name: String): Boolean {
        val result = runCommand("command -v $name")
        return result.exitCode == 0 && result.stdout.isNotBlank()
    }

    /**
     * Get Python version (useful smoke test).
     */
    fun pythonVersion(): String {
        return exec("python3 --version 2>&1 || python --version 2>&1")
    }
}