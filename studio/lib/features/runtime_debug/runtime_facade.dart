import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/embedded_runtime.dart';

class RuntimeFailure implements Exception {
  const RuntimeFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

class RuntimeCommandOutput {
  const RuntimeCommandOutput({required this.exitCode, required this.output});

  final int exitCode;
  final String output;

  bool get ok => exitCode == 0;
}

abstract class RuntimeFacade {
  Future<bool> isReady();

  /// Cheap ready + python presence (no proot). Prefer this for tab open.
  Future<({bool ready, bool hasPython})> probeStatus();

  Future<void> initialize({
    required void Function(String message, double? fraction) onProgress,
  });

  Future<String?> pythonVersion();

  Future<RuntimeCommandOutput> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  });

  Future<RuntimeCommandOutput> installPackages(List<String> packages);
}

class EmbeddedRuntimeFacade implements RuntimeFacade {
  const EmbeddedRuntimeFacade();

  @override
  Future<bool> isReady() => EmbeddedRuntime.isReady();

  @override
  Future<({bool ready, bool hasPython})> probeStatus() =>
      EmbeddedRuntime.probeStatus();

  @override
  Future<void> initialize({
    required void Function(String message, double? fraction) onProgress,
  }) async {
    final sub = EmbeddedRuntime.progressStream.listen((event) {
      onProgress(event.message, _fraction(event.percent));
    });
    try {
      final result = await EmbeddedRuntime.initialize();
      if (!result.success) {
        final error = (result.error ?? '').trim();
        throw RuntimeFailure(error.isEmpty ? 'Initialize failed' : error);
      }
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<String?> pythonVersion() async {
    final v = (await EmbeddedRuntime.pythonVersion()).trim();
    if (v.isEmpty) return null;
    final lower = v.toLowerCase();
    if (lower.contains('not found') || lower.contains('no such')) return null;
    return v;
  }

  @override
  Future<RuntimeCommandOutput> run(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final r = await EmbeddedRuntime.runCommand(
      command,
      timeoutSec: timeout.inSeconds.clamp(1, 3600),
    );
    if (r.timedOut) {
      throw TimeoutException('Command timed out', timeout);
    }
    final out = r.stdout;
    final err = r.stderr;
    final combined = err.isEmpty
        ? out
        : (out.isEmpty ? err : '$out\n$err');
    return RuntimeCommandOutput(exitCode: r.exitCode, output: combined);
  }

  @override
  Future<RuntimeCommandOutput> installPackages(List<String> packages) async {
    final result = await EmbeddedRuntime.installPackages(packages);
    final output = result.error.isEmpty
        ? result.output
        : (result.output.isEmpty
            ? result.error
            : '${result.output}\n${result.error}');
    return RuntimeCommandOutput(
      exitCode: result.success ? 0 : 1,
      output: output,
    );
  }
}

final runtimeFacadeProvider = Provider<RuntimeFacade>(
  (ref) => const EmbeddedRuntimeFacade(),
);

double? _fraction(num? p) {
  if (p == null) return null;
  final v = p is int ? p / 100.0 : (p <= 1 ? p.toDouble() : p / 100.0);
  return v.clamp(0.0, 1.0).toDouble();
}
