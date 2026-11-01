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
        java.util.concurrent.ArrayBlockingQueue(8),
        { r -> Thread(r, "nexus-runtime-worker").apply { isDaemon = true } },
        java.util.concurrent.ThreadPoolExecutor.AbortPolicy()
    )
    private val mainHandler = Handler(Looper.getMainLooper())

    private var progressSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "com.nexus/runtime")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "com.nexus/runtime/progress")
        eventChannel.setStreamHandler(this)

        runtime = NexusRuntime.getInstance(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        progressSink = null
        executor.shutdown()
        try {
            // Give in-flight work a short chance to finish, then force
            if (!executor.awaitTermination(3, java.util.concurrent.TimeUnit.SECONDS)) {
                executor.shutdownNow()
            }
        } catch (_: InterruptedException) {
            executor.shutdownNow()
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
        try {
            executor.execute {
                try {
                    val value = block()
                    mainHandler.post {
                        try {
                            result.success(value)
                        } catch (t: Throwable) {
                            RuntimeLogger.e("Failed to send success for $tag", t)
                        }
                    }
                } catch (t: Throwable) {
                    RuntimeLogger.e("Worker error in $tag", t)
                    mainHandler.post {
                        try {
                            result.error(
                            "NATIVE_ERROR",
                            "$tag: ${t.javaClass.simpleName}: ${t.message}",
                            t.stackTraceToString()
                        )
                        } catch (_: Throwable) {
                            // Result already used or channel gone
                        }
                    }
                }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            RuntimeLogger.e("Worker rejected for $tag", e)
            try {
                result.error("NATIVE_BUSY", "$tag: runtime busy or shutting down", null)
            } catch (_: Throwable) {
                // ignored
            }
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
                val ready = try {
                    runtime.isReady
                } catch (t: Throwable) {
                    RuntimeLogger.e("isReady check failed", t)
                    false
                }
                result.success(ready)
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
                        "timedOut" to cmdResult.timedOut
                    )
                }
            }

            "getPrefixPath" -> result.success(runtime.getPrefixPath())
            "getRuntimeRoot" -> result.success(runtime.getRuntimeRoot())

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

            else -> result.notImplemented()
        }
    }
}
