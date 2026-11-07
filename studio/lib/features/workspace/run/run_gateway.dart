import '../../../services/embedded_runtime.dart';
import 'run_session.dart';

enum RuntimeReadiness { notReady, noPython, ready }

class SessionRunResult {
  const SessionRunResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.timedOut = false,
    this.stoppedByUser = false,
    this.error,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final bool stoppedByUser;
  final String? error;
}

/// Controller depends on this interface (easy to fake in tests).
abstract class RunGateway {
  Future<RuntimeReadiness> readiness();
  Future<SessionRunResult> run(String projectId, {required int timeoutSec});
  Future<bool> stop();
}

class DefaultRunGateway implements RunGateway {
  const DefaultRunGateway();

  @override
  Future<RuntimeReadiness> readiness() async {
    // probeStatus is filesystem-only; keys: ready, hasPython (not "python")
    final status = await EmbeddedRuntime.probeStatus();
    if (status.ready != true) return RuntimeReadiness.notReady;
    if (status.hasPython != true) return RuntimeReadiness.noPython;
    return RuntimeReadiness.ready;
  }

  @override
  Future<SessionRunResult> run(String projectId, {required int timeoutSec}) async {
    try {
      final m = await EmbeddedRuntime.runProject(
        projectId,
        timeoutSec: timeoutSec,
      );
      return SessionRunResult(
        exitCode: m.exitCode,
        stdout: m.stdout,
        stderr: m.stderr,
        timedOut: m.timedOut,
        stoppedByUser: m.stoppedByUser,
      );
    } catch (e) {
      return SessionRunResult(exitCode: -1, error: e.toString());
    }
  }

  @override
  Future<bool> stop() => EmbeddedRuntime.stopRun();
}
