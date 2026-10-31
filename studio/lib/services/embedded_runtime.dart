import 'package:flutter/services.dart';

/// Flutter-side API for the Nexus Embedded Linux Runtime.
///
/// This is the only class Studio code should talk to for running
/// commands inside the embedded environment.
class EmbeddedRuntime {
  static const MethodChannel _channel = MethodChannel('com.nexus/runtime');

  /// Initialize / extract bootstrap. Call once at app start (preferably with loading UI).
  static Future<RuntimeInitResult> initialize() async {
    final result = await _channel.invokeMethod<Map>('initialize');
    if (result == null) {
      return RuntimeInitResult(success: false, error: 'Null response from native');
    }
    return RuntimeInitResult(
      success: result['success'] == true,
      error: result['error'] as String?,
    );
  }

  static Future<bool> isReady() async {
    return await _channel.invokeMethod<bool>('isReady') ?? false;
  }

  /// Run a command inside the embedded Linux environment.
  static Future<CommandResult> runCommand(
    String command, {
    String? workingDir,
    int timeoutSec = 60,
  }) async {
    final result = await _channel.invokeMethod<Map>('runCommand', {
      'command': command,
      'workingDir': workingDir,
      'timeoutSec': timeoutSec,
    });

    if (result == null) {
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Null response from native',
        timedOut: false,
      );
    }

    return CommandResult(
      exitCode: result['exitCode'] as int? ?? -1,
      stdout: result['stdout'] as String? ?? '',
      stderr: result['stderr'] as String? ?? '',
      timedOut: result['timedOut'] as bool? ?? false,
    );
  }

  static Future<String> getPrefixPath() async {
    return await _channel.invokeMethod<String>('getPrefixPath') ?? '';
  }

  static Future<String> getRuntimeRoot() async {
    return await _channel.invokeMethod<String>('getRuntimeRoot') ?? '';
  }

  static Future<String> pythonVersion() async {
    return await _channel.invokeMethod<String>('pythonVersion') ?? 'unknown';
  }

  static Future<bool> hasBinary(String name) async {
    return await _channel.invokeMethod<bool>('hasBinary', {'name': name}) ?? false;
  }

  /// Convenience helper
  static Future<String> exec(String command) async {
    final result = await runCommand(command);
    if (result.exitCode == 0) return result.stdout;
    return 'ERROR(${result.exitCode}): ${result.stderr}';
  }
}

class RuntimeInitResult {
  final bool success;
  final String? error;

  RuntimeInitResult({required this.success, this.error});
}

class CommandResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
  });

  bool get isSuccess => exitCode == 0 && !timedOut;

  @override
  String toString() {
    return 'CommandResult(exitCode: $exitCode, timedOut: $timedOut)\n'
        'stdout:\n$stdout\n'
        'stderr:\n$stderr';
  }
}