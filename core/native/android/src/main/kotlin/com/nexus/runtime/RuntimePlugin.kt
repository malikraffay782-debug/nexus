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
 * EventChannel  : com.nexus/runtime/progress   (for bootstrap progress)
 */
class RuntimePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var runtime: NexusRuntime
    private val executor = Executors.newSingleThreadExecutor()
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
        executor.shutdown()
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

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                executor.execute {
                    val initResult = runtime.initialize { percent, message ->
                        sendProgress(percent, message)
                    }
                    mainHandler.post {
                        if (initResult.isSuccess) {
                            result.success(mapOf("success" to true))
                        } else {
                            result.success(
                                mapOf(
                                    "success" to false,
                                    "error" to (initResult.exceptionOrNull()?.message ?: "Unknown error")
                                )
                            )
                        }
                    }
                }
            }

            "isReady" -> result.success(runtime.isReady)

            "runCommand" -> {
                val command = call.argument<String>("command")
                if (command.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "command is required", null)
                    return
                }
                val workingDir = call.argument<String>("workingDir")
                val timeoutSec = call.argument<Int>("timeoutSec")?.toLong() ?: 60L

                executor.execute {
                    val cmdResult = runtime.runCommand(command, workingDir, timeoutSec)
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "exitCode" to cmdResult.exitCode,
                                "stdout" to cmdResult.stdout,
                                "stderr" to cmdResult.stderr,
                                "timedOut" to cmdResult.timedOut
                            )
                        )
                    }
                }
            }

            "getPrefixPath" -> result.success(runtime.getPrefixPath())
            "getRuntimeRoot" -> result.success(runtime.getRuntimeRoot())

            "pythonVersion" -> {
                executor.execute {
                    val v = runtime.pythonVersion()
                    mainHandler.post { result.success(v) }
                }
            }

            "hasBinary" -> {
                val name = call.argument<String>("name")
                if (name.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "name is required", null)
                    return
                }
                executor.execute {
                    val exists = runtime.hasBinary(name)
                    mainHandler.post { result.success(exists) }
                }
            }

            "installPackage" -> {
                val packages = call.argument<List<String>>("packages")
                if (packages.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "packages list required", null)
                    return
                }
                executor.execute {
                    val installResult = runtime.packages.install(packages)
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "success" to installResult.success,
                                "output" to installResult.output,
                                "error" to installResult.error
                            )
                        )
                    }
                }
            }

            "updatePackages" -> {
                executor.execute {
                    val updateResult = runtime.packages.update()
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "success" to updateResult.success,
                                "output" to updateResult.output,
                                "error" to updateResult.error
                            )
                        )
                    }
                }
            }

            else -> result.notImplemented()
        }
    }
}