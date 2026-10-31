package com.nexus.runtime

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.Executors

/**
 * Flutter MethodChannel plugin for the Embedded Runtime.
 *
 * Channel name: com.nexus/runtime
 *
 * Methods:
 *   - initialize()          → {success: bool, error?: string}
 *   - isReady()             → bool
 *   - runCommand(command, workingDir?, timeoutSec?) → {exitCode, stdout, stderr, timedOut}
 *   - getPrefixPath()       → string
 *   - pythonVersion()       → string
 *   - hasBinary(name)       → bool
 */
class RuntimePlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var runtime: NexusRuntime
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.nexus/runtime")
        channel.setMethodCallHandler(this)
        runtime = NexusRuntime.getInstance(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                executor.execute {
                    val initResult = runtime.initialize()
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

            "isReady" -> {
                result.success(runtime.isReady)
            }

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

            "getPrefixPath" -> {
                result.success(runtime.getPrefixPath())
            }

            "getRuntimeRoot" -> {
                result.success(runtime.getRuntimeRoot())
            }

            "pythonVersion" -> {
                executor.execute {
                    val version = runtime.pythonVersion()
                    mainHandler.post { result.success(version) }
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

            else -> result.notImplemented()
        }
    }
}