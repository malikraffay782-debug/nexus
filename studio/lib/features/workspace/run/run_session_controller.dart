import 'package:flutter/foundation.dart';

import 'run_gateway.dart';
import 'run_session.dart';

class RunSessionController extends ChangeNotifier {
  RunSessionController(this._gateway);

  final RunGateway _gateway;

  RunSessionState _state = const RunSessionState(phase: RunPhase.idle);
  RunSessionState get state => _state;

  /// Set before any await — blocks double-tap race.
  bool _launching = false;

  int _generation = 0;
  bool _stopRequested = false;
  bool _disposed = false;

  Future<void> run(String projectId, {int timeoutSec = 60}) async {
    if (_launching || _state.phase.isBusy) return;
    _launching = true;
    final gen = ++_generation;
    _stopRequested = false;

    try {
      _emit(const RunSessionState(phase: RunPhase.checking));
      final readiness = await _gateway.readiness();
      if (!_isCurrent(gen)) return;

      switch (readiness) {
        case RuntimeReadiness.notReady:
          _fail(
            gen,
            'Runtime is not ready. Open the Runtime tab and tap Initialize.',
          );
          return;
        case RuntimeReadiness.noPython:
          _fail(
            gen,
            'Python is not installed. Open the Runtime tab and tap Install Python.',
          );
          return;
        case RuntimeReadiness.ready:
          break;
      }

      final started = DateTime.now();
      _emit(RunSessionState(phase: RunPhase.starting, startedAt: started));
      if (!_isCurrent(gen)) return;
      _emit(RunSessionState(phase: RunPhase.running, startedAt: started));

      final result = await _gateway.run(projectId, timeoutSec: timeoutSec);
      if (!_isCurrent(gen)) return;
      _finish(gen, result, started);
    } catch (e) {
      if (_isCurrent(gen)) {
        _fail(gen, 'Could not start run. $e');
      }
    } finally {
      _launching = false;
    }
  }

  Future<void> stop() async {
    if (_stopRequested) return;
    final phase = _state.phase;

    if (phase == RunPhase.checking) {
      _generation++;
      _emit(const RunSessionState(phase: RunPhase.idle));
      return;
    }
    if (phase != RunPhase.starting && phase != RunPhase.running) return;

    _stopRequested = true;
    _emit(RunSessionState(
      phase: RunPhase.stopping,
      startedAt: _state.startedAt,
      stdout: _state.stdout,
      stderr: _state.stderr,
    ));
    await _gateway.stop();
    // Final phase comes from run() completion.
  }

  /// Call when leaving the project screen.
  Future<void> detach() async {
    _generation++;
    final wasBusy = _state.phase.isBusy;
    _emit(const RunSessionState(phase: RunPhase.idle));
    if (wasBusy) await _gateway.stop();
  }

  bool _isCurrent(int gen) => !_disposed && gen == _generation;

  void _fail(int gen, String message) {
    if (!_isCurrent(gen)) return;
    _emit(RunSessionState(
      phase: RunPhase.failed,
      stdout: _state.stdout,
      stderr: _state.stderr,
      errorMessage: message,
      startedAt: _state.startedAt,
      endedAt: DateTime.now(),
    ));
  }

  void _finish(int gen, SessionRunResult r, DateTime started) {
    final stdout = capOutput(r.stdout);
    final stderr = capOutput(r.stderr);
    final stopped = r.stoppedByUser || _stopRequested;

    final String? message;
    final RunPhase phase;

    if (stopped) {
      phase = RunPhase.cancelled;
      message = 'Stopped by user';
    } else if (r.timedOut) {
      phase = RunPhase.failed;
      message = 'Timed out';
    } else if (r.error != null) {
      phase = RunPhase.failed;
      message = r.error;
    } else if (r.exitCode == 127) {
      phase = RunPhase.failed;
      message = 'python3 not found. Open the Runtime tab → Install Python.';
    } else if (r.exitCode != 0) {
      phase = RunPhase.failed;
      message = 'Exit code ${r.exitCode}';
    } else {
      phase = RunPhase.finished;
      message = null;
    }

    _emit(RunSessionState(
      phase: phase,
      stdout: stdout,
      stderr: stderr,
      exitCode: r.exitCode,
      timedOut: r.timedOut,
      errorMessage: message,
      startedAt: started,
      endedAt: DateTime.now(),
    ));
  }

  void _emit(RunSessionState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    if (_state.phase.isBusy) {
      _gateway.stop();
    }
    super.dispose();
  }
}
