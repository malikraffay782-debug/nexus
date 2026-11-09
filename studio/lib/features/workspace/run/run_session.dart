enum RunPhase { idle, checking, starting, running, stopping, finished, failed, cancelled }

extension RunPhaseX on RunPhase {
  bool get isBusy =>
      this == RunPhase.checking ||
      this == RunPhase.starting ||
      this == RunPhase.running ||
      this == RunPhase.stopping;
}

const int kMaxOutputChars = 200000;
const String kTruncationMarker =
    '\n…[output truncated at $kMaxOutputChars chars]\n';

String capOutput(String text) {
  if (text.length <= kMaxOutputChars) return text;
  return text.substring(0, kMaxOutputChars) + kTruncationMarker;
}

class RunSessionState {
  const RunSessionState({
    required this.phase,
    this.stdout = '',
    this.stderr = '',
    this.exitCode,
    this.timedOut = false,
    this.errorMessage,
    this.startedAt,
    this.endedAt,
  });

  final RunPhase phase;
  final String stdout;
  final String stderr;
  final int? exitCode;
  final bool timedOut;
  final String? errorMessage;
  final DateTime? startedAt;
  final DateTime? endedAt;

  Duration? get duration => (startedAt != null && endedAt != null)
      ? endedAt!.difference(startedAt!)
      : null;
}
