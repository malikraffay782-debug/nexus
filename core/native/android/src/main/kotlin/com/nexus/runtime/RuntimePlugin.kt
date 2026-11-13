package com.nexus.runtime

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.Executors

/**
 * Flutter bridge for Nexus Embedded Runtime.
 *
 * MethodChannel : com.nexus/runtime
 * EventChannel  : com.nexus/runtime/progress
 */
class RuntimePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var runtime: NexusRuntime

    // Allow multiple concurrent commands (install can be long)
    // AbortPolicy: never run heavy work on the Flutter platform thread (ANR risk)
    private val executor = java.util.concurrent.ThreadPoolExecutor(
        2, 4,
        30L, java.util.concurrent.TimeUnit.SECONDS,
        java.util.concurrent.ArrayBlockingQueue(32),
        { r -> Thread(r, "nexus-runtime-worker").apply { isDaemon = true } },
        java.util.concurrent.ThreadPoolExecutor.AbortPolicy()
    )
    private val mainHandler = Handler(Looper.getMainLooper())

    private var progressSink: EventChannel.EventSink? = null
    @Volatile private var destroyed = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        destroyed = false
        methodChannel = MethodChannel(binding.binaryMessenger, "com.nexus/runtime")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "com.nexus/runtime/progress")
        eventChannel.setStreamHandler(this)

        runtime = NexusRuntime.getInstance(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        destroyed = true
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        progressSink = null
        executor.shutdownNow()
        try {
            executor.awaitTermination(2, java.util.concurrent.TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }

    private fun sendProgress(percent: Int, message: String) {
        mainHandler.post {
            progressSink?.success(mapOf("percent" to percent, "message" to message))
        }
    }

    /**
     * Run work on background thread and always complete the Flutter Result
     * (success or error). Prevents Dart Futures from hanging forever.
     */
    private fun <T> onWorker(result: Result, tag: String, block: () -> T) {
        if (destroyed) {
            try { result.error("NATIVE_DETACHED", "$tag: plugin is detached", null) } catch (_: Throwable) {}
            return
        }
        try {
            executor.execute {
                if (destroyed) {
                    mainHandler.post {
                        try { result.error("NATIVE_DETACHED", "$tag: plugin is detached", null) } catch (_: Throwable) {}
                    }
                    return@execute
                }
                try {
                    val value = block()
                    mainHandler.post {
                        if (destroyed) return@post
                        try {
                            result.success(value)
                        } catch (t: Throwable) {
                            RuntimeLogger.e("Failed to send success for $tag", t)
                        }
                    }
                } catch (t: Throwable) {
                    RuntimeLogger.e("Worker error in $tag", t)
                    mainHandler.post {
                        if (destroyed) return@post
                        try {
                            result.error(
                                "NATIVE_ERROR",
                                "$tag: ${t.javaClass.simpleName}: ${t.message}",
                                t.stackTraceToString()
                            )
                        } catch (_: Throwable) {}
                    }
                }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            RuntimeLogger.e("Worker rejected for $tag", e)
            try {
                result.error("NATIVE_BUSY", "$tag: runtime busy or shutting down", null)
            } catch (_: Throwable) {}
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                onWorker(result, "initialize") {
                    val initResult = runtime.initialize { percent, message ->
                        sendProgress(percent, message)
                    }
                    if (initResult.isSuccess) {
                        mapOf("success" to true)
                    } else {
                        mapOf(
                            "success" to false,
                            "error" to (initResult.exceptionOrNull()?.message ?: "Unknown error")
                        )
                    }
                }
            }

            "isReady" -> {
                onWorker(result, "isReady") {
                    val ready = try {
                        runtime.isReady
                    } catch (t: Throwable) {
                        RuntimeLogger.e("isReady check failed", t)
                        false
                    }
                    mapOf("ready" to ready)
                }
            }

            // Cheap status for UI (no proot spawn). Use this on every tab open.
            "probeStatus" -> {
                onWorker(result, "probeStatus") {
                    try {
                        runtime.probeStatus()
                    } catch (t: Throwable) {
                        RuntimeLogger.e("probeStatus failed", t)
                        mapOf("ready" to false, "hasPython" to false, "hasCpp" to false)
                    }
                }
            }

            "runCommand" -> {
                val command = call.argument<String>("command")
                if (command.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "command is required", null)
                    return
                }
                val workingDir = call.argument<String>("workingDir")
                val timeoutSec = call.argument<Int>("timeoutSec")?.toLong() ?: 60L

                onWorker(result, "runCommand") {
                    val cmdResult = runtime.runCommand(command, workingDir, timeoutSec)
                    mapOf(
                        "exitCode" to cmdResult.exitCode,
                        "stdout" to cmdResult.stdout,
                        "stderr" to cmdResult.stderr,
                        "timedOut" to cmdResult.timedOut,
                        "stoppedByUser" to cmdResult.stoppedByUser
                    )
                }
            }

            "getPrefixPath" -> onWorker(result, "getPrefixPath") { runtime.getPrefixPath() }
            "getRuntimeRoot" -> onWorker(result, "getRuntimeRoot") { runtime.getRuntimeRoot() }

            "runProject" -> {
                val projectId = call.argument<String>("projectId")
                if (projectId.isNullOrBlank()) {
                    result.error("bad_args", "projectId required", null)
                    return
                }
                // Prefer timeoutSec. Legacy timeoutMs is always milliseconds.
                val timeoutSec = run {
                    val secArg = call.argument<Number>("timeoutSec")?.toLong()
                    if (secArg != null) return@run secArg.coerceIn(1L, 120L)
                    val msArg = call.argument<Number>("timeoutMs")?.toLong()
                    if (msArg != null) {
                        return@run (msArg / 1000L).coerceIn(1L, 120L)
                    }
                    30L
                }
                onWorker(result, "runProject") {
                    val cmdResult = runtime.runProject(projectId, timeoutSec)
                    mapOf(
                        "exitCode" to cmdResult.exitCode,
                        "stdout" to cmdResult.stdout,
                        "stderr" to cmdResult.stderr,
                        "timedOut" to cmdResult.timedOut,
                        "stoppedByUser" to cmdResult.stoppedByUser
                    )
                }
            }

            "pythonVersion" -> {
                onWorker(result, "pythonVersion") {
                    runtime.pythonVersion()
                }
            }

            "hasBinary" -> {
                val name = call.argument<String>("name")
                if (name.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "name is required", null)
                    return
                }
                onWorker(result, "hasBinary") {
                    runtime.hasBinary(name)
                }
            }

            "installPackage" -> {
                val raw = call.argument<List<*>>("packages")
                val packages = raw?.filterIsInstance<String>() ?: emptyList()
                if (packages.isEmpty()) {
                    result.error("INVALID_ARGS", "packages list required", null)
                    return
                }
                onWorker(result, "installPackage") {
                    val installResult = runtime.packages.install(packages)
                    mapOf(
                        "success" to installResult.success,
                        "output" to installResult.output,
                        "error" to installResult.error
                    )
                }
            }

            "updatePackages" -> {
                onWorker(result, "updatePackages") {
                    val updateResult = runtime.packages.update()
                    mapOf(
                        "success" to updateResult.success,
                        "output" to updateResult.output,
                        "error" to updateResult.error
                    )
                }
            }

            "installCpp" -> {
                onWorker(result, "installCpp") {
                    val installResult = runtime.installCpp()
                    mapOf(
                        "success" to installResult.success,
                        "output" to installResult.output,
                        "error" to installResult.error
                    )
                }
            }

            "cppVersion" -> {
                onWorker(result, "cppVersion") {
                    runtime.cppVersion()
                }
            }

            "getProjectsRoot" -> {
                try {
                    result.success(runtime.projectsRootPath())
                } catch (e: Exception) {
                    result.error("projects_root", e.message, null)
                }
            }

            "stopRun" -> {
                // Synchronous: only signals process; must not block on runMutex
                try {
                    result.success(runtime.stopRun())
                } catch (e: Exception) {
                    result.error("stop_failed", e.message, null)
                }
            }


            "wipeRuntime" -> {
                onWorker(result, "wipeRuntime") {
                    val wipe = runtime.wipeRuntime()
                    mapOf(
                        "success" to wipe.success,
                        "error" to (wipe.error ?: "")
                    )
                }
            }

            else -> result.notImplemented()
        }
    }
}
