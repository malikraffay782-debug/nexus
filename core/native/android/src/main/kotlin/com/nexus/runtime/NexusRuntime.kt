package com.nexus.runtime

import android.content.Context
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * Main entry point for the Embedded Linux Runtime.
 *
 * initialize() takes a write lock (may delete/recreate prefix).
 * runCommand() / package ops take a read lock so they cannot race with re-bootstrap.
 */
class NexusRuntime private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val bootstrapManager = BootstrapManager(appContext)
    private val executor = ProotExecutor(appContext, bootstrapManager)
    private val runtimeLock = ReentrantReadWriteLock()

    val packages = PackageManager { command, timeoutSec ->
        runtimeLock.read {
            executor.run(command, null, timeoutSec)
        }
    }

    companion object {
        @Volatile
        private var instance: NexusRuntime? = null

        fun getInstance(context: Context): NexusRuntime {
            return instance ?: synchronized(this) {
                instance ?: NexusRuntime(context).also { instance = it }
            }
        }
    }

    fun initialize(onProgress: ((Int, String) -> Unit)? = null): Result<Unit> {
        RuntimeLogger.i("Initializing Nexus Embedded Runtime...")
        return runtimeLock.write {
            bootstrapManager.ensureBootstrap(onProgress)
        }
    }

    val isReady: Boolean
        get() = try {
            bootstrapManager.isReady
        } catch (_: Throwable) {
            false
        }

    fun getPrefixPath(): String = bootstrapManager.getPrefixPath()
    fun getRuntimeRoot(): String = bootstrapManager.getRuntimeRootPath()

    fun runCommand(
        command: String,
        workingDir: String? = null,
        timeoutSec: Long = 60
    ): ProotExecutor.CommandResult {
        if (command.isBlank()) {
            return ProotExecutor.CommandResult(-1, "", "empty command", false)
        }
        return runtimeLock.read {
            executor.run(command, workingDir, timeoutSec)
        }
    }

    fun exec(command: String): ProotExecutor.CommandResult = runCommand(command)

    fun execToString(command: String): String {
        val result = runCommand(command)
        return when {
            result.exitCode == 0 -> result.stdout.ifBlank { result.stderr }
            result.stdout.isNotBlank() && result.stderr.isNotBlank() ->
                "ERROR(${result.exitCode}): ${result.stderr}\n${result.stdout}"
            result.stdout.isNotBlank() -> "ERROR(${result.exitCode}): ${result.stdout}"
            else -> "ERROR(${result.exitCode}): ${result.stderr.ifBlank { "no output" }}"
        }
    }

    fun hasBinary(name: String): Boolean {
        if (!name.matches(Regex("^[a-zA-Z0-9][a-zA-Z0-9._+-]*$"))) {
            return false
        }
        val result = runCommand("command -v '$name' >/dev/null 2>&1 && echo yes || echo no")
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
