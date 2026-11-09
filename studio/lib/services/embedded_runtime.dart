import 'dart:async';
import 'package:flutter/services.dart';

/// Flutter-side API for the Nexus Embedded Linux Runtime.
class EmbeddedRuntime {
  static const MethodChannel _channel = MethodChannel('com.nexus/runtime');
  static const EventChannel _progressChannel = EventChannel('com.nexus/runtime/progress');

  static Stream<RuntimeProgress>? _progressStream;

  /// Single broadcast stream — avoids native listener leaks from repeated access.
  /// On full engine restart, process restart recreates this; hot-reload may need app restart.
  static Stream<RuntimeProgress> get progressStream {
    return _progressStream ??= _progressChannel.receiveBroadcastStream().map((event) {
      final map = event is Map
          ? Map<String, dynamic>.from(event)
          : <String, dynamic>{};
      return RuntimeProgress(
        percent: map['percent'] as int? ?? 0,
        message: map['message'] as String? ?? '',
      );
    });
  }

  static Future<RuntimeInitResult> initialize() async {
    try {
      final result = await _channel
          .invokeMethod<Map>('initialize')
          .timeout(const Duration(seconds: 180));
      if (result == null) {
        return RuntimeInitResult(success: false, error: 'Null response from native');
      }
      return RuntimeInitResult(
        success: result['success'] == true,
        error: result['error'] as String?,
      );
    } on PlatformException catch (e) {
      return RuntimeInitResult(success: false, error: '${e.code}: ${e.message}');
    } on TimeoutException {
      return RuntimeInitResult(success: false, error: 'Initialize timed out');
    } catch (e) {
      return RuntimeInitResult(success: false, error: e.toString());
    }
  }

  static Future<bool> isReady() async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('isReady')
          .timeout(const Duration(seconds: 5));
      if (raw is bool) return raw;
      if (raw is Map) return raw['ready'] == true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Filesystem-only status. Does not start proot — use on every screen open.
  /// [error] is set when the channel/native call fails (not the same as !ready).
  static Future<({bool ready, bool hasPython, String? error})> probeStatus() async {
    try {
      final raw = await _channel
          .invokeMethod<dynamic>('probeStatus')
          .timeout(const Duration(seconds: 5));
      if (raw is Map) {
        return (
          ready: raw['ready'] == true,
          hasPython: raw['hasPython'] == true,
          error: null,
        );
      }
      return (ready: false, hasPython: false, error: 'Unexpected probe response');
    } catch (e) {
      return (ready: false, hasPython: false, error: e.toString());
    }
  }

  static Future<CommandResult> runCommand(
    String command, {
    String? workingDir,
    int timeoutSec = 60,
  }) async {
    if (timeoutSec <= 0) {
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: 'timeoutSec must be > 0',
        timedOut: false,
      );
    }
    try {
      final result = await _channel
          .invokeMethod<Map>('runCommand', {
            'command': command,
            'workingDir': workingDir,
            'timeoutSec': timeoutSec,
          })
          .timeout(Duration(seconds: timeoutSec + 15));

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
        stoppedByUser: result['stoppedByUser'] as bool? ?? false,
      );
    } on PlatformException catch (e) {
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: '${e.code}: ${e.message}',
        timedOut: false,
      );
    } on TimeoutException {
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Native call timed out',
        timedOut: true,
      );
    } catch (e) {
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: e.toString(),
        timedOut: false,
      );
    }
  }

  static Future<String> getPrefixPath() async {
    try {
      return await _channel.invokeMethod<String>('getPrefixPath') ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<String> getRuntimeRoot() async {
    try {
      return await _channel.invokeMethod<String>('getRuntimeRoot') ?? '';
    } catch (_) {
      return '';
    }
  }

  
  /// Run project src/main.py inside proot (host project dir bound at /home/project).
  /// Only [projectId] is sent — native code resolves and validates the path.
  static Future<CommandResult> runProject(
    String projectId, {
    int timeoutSec = 30,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>(
        'runProject',
        {
          'projectId': projectId,
          'timeoutSec': timeoutSec,
        },
      ).timeout(Duration(seconds: timeoutSec + 15));
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
        stoppedByUser: result['stoppedByUser'] as bool? ?? false,
      );
    } on PlatformException catch (e) {
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: e.message ?? e.code,
        timedOut: false,
      );
    } on TimeoutException {
      // Native may still hold runMutex — request stop so the next Run is not stuck.
      try {
        await stopRun();
      } catch (_) {}
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Native call timed out',
        timedOut: true,
      );
    } catch (e) {
      return CommandResult(
        exitCode: -1,
        stdout: '',
        stderr: e.toString(),
        timedOut: false,
      );
    }
  }

  /// Android: same path as native `getDir("flutter")/projects`.
  /// Other platforms: null (caller should use path_provider).
  static Future<String?> getProjectsRoot() async {
    try {
      final path = await _channel.invokeMethod<String>('getProjectsRoot')
          .timeout(const Duration(seconds: 5));
      if (path == null || path.isEmpty) return null;
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Best-effort stop of the active proot run (native TERM/KILL).
  static Future<bool> stopRun() async {
    try {
      final result = await _channel.invokeMethod<Map>('stopRun')
          .timeout(const Duration(seconds: 8));
      return result?['stopped'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> pythonVersion() async {
    try {
      return await _channel
              .invokeMethod<String>('pythonVersion')
              .timeout(const Duration(seconds: 30)) ??
          'unknown';
    } catch (e) {
      return 'error: $e';
    }
  }

  static Future<bool> hasBinary(String name) async {
    try {
      return await _channel
              .invokeMethod<bool>('hasBinary', {'name': name})
              .timeout(const Duration(seconds: 15)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<PackageResult> installPackages(List<String> packages) async {
    try {
      final result = await _channel
          .invokeMethod<Map>('installPackage', {'packages': packages})
          .timeout(const Duration(minutes: 12));
      if (result == null) {
        return PackageResult(success: false, output: '', error: 'Null response');
      }
      return PackageResult(
        success: result['success'] == true,
        output: result['output'] as String? ?? '',
        error: result['error'] as String? ?? '',
      );
    } on PlatformException catch (e) {
      return PackageResult(success: false, output: '', error: '${e.code}: ${e.message}');
    } on TimeoutException {
      return PackageResult(success: false, output: '', error: 'Install timed out');
    } catch (e) {
      return PackageResult(success: false, output: '', error: e.toString());
    }
  }

  static Future<PackageResult> updatePackages() async {
    try {
      final result = await _channel
          .invokeMethod<Map>('updatePackages')
          .timeout(const Duration(minutes: 3));
      if (result == null) {
        return PackageResult(success: false, output: '', error: 'Null response');
      }
      return PackageResult(
        success: result['success'] == true,
        output: result['output'] as String? ?? '',
        error: result['error'] as String? ?? '',
      );
    } on PlatformException catch (e) {
      return PackageResult(success: false, output: '', error: '${e.code}: ${e.message}');
    } on TimeoutException {
      return PackageResult(success: false, output: '', error: 'Update timed out');
    } catch (e) {
      return PackageResult(success: false, output: '', error: e.toString());
    }
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
  final bool stoppedByUser;

  CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
    this.stoppedByUser = false,
  });

  bool get isSuccess => exitCode == 0 && !timedOut && !stoppedByUser;

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
