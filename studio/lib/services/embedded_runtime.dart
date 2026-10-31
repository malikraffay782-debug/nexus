import 'dart:async';
import 'package:flutter/services.dart';

/// Flutter-side API for the Nexus Embedded Linux Runtime.
class EmbeddedRuntime {
  static const MethodChannel _channel = MethodChannel('com.nexus/runtime');
  static const EventChannel _progressChannel = EventChannel('com.nexus/runtime/progress');

  static Stream<RuntimeProgress>? _progressStream;

  /// Listen to bootstrap progress (percent + message)
  static Stream<RuntimeProgress> get progressStream {
    _progressStream ??= _progressChannel
        .receiveBroadcastStream()
        .map((event) {
          final map = Map<String, dynamic>.from(event as Map);
          return RuntimeProgress(
            percent: map['percent'] as int? ?? 0,
            message: map['message'] as String? ?? '',
          );
        });
    return _progressStream!;
  }

  /// Initialize / extract bootstrap.
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

  /// Install one or more packages
  static Future<PackageResult> installPackages(List<String> packages) async {
    final result = await _channel.invokeMethod<Map>('installPackage', {
      'packages': packages,
    });
    if (result == null) {
      return PackageResult(success: false, output: '', error: 'Null response');
    }
    return PackageResult(
      success: result['success'] == true,
      output: result['output'] as String? ?? '',
      error: result['error'] as String? ?? '',
    );
  }

  static Future<PackageResult> updatePackages() async {
    final result = await _channel.invokeMethod<Map>('updatePackages');
    if (result == null) {
      return PackageResult(success: false, output: '', error: 'Null response');
    }
    return PackageResult(
      success: result['success'] == true,
      output: result['output'] as String? ?? '',
      error: result['error'] as String? ?? '',
    );
  }

  static Future<String> exec(String command) async {
    final result = await runCommand(command);
    if (result.exitCode == 0) return result.stdout;
    return 'ERROR(${result.exitCode}): ${result.stderr}';
  }
}

class RuntimeProgress {
  final int percent;
  final String message;
  RuntimeProgress({required this.percent, required this.message});
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
    return 'CommandResult(exitCode: $exitCode, timedOut: $timedOut)\nstdout:\n$stdout\nstderr:\n$stderr';
  }
}

class PackageResult {
  final bool success;
  final String output;
  final String error;
  PackageResult({required this.success, required this.output, required this.error});
}