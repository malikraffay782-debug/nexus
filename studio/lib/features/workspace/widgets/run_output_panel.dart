import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../run/run_session.dart';

class RunOutputPanel extends StatelessWidget {
  const RunOutputPanel({
    super.key,
    required this.state,
    required this.onStop,
    this.onClose,
  });

  final RunSessionState state;
  final VoidCallback onStop;
  final VoidCallback? onClose;

  String get _phaseLabel => switch (state.phase) {
        RunPhase.idle => 'Idle',
        RunPhase.checking => 'Checking runtime…',
        RunPhase.starting => 'Starting…',
        RunPhase.running => 'Running…',
        RunPhase.stopping => 'Stopping…',
        RunPhase.finished => 'Finished (exit 0)',
        RunPhase.failed => state.errorMessage ?? 'Failed',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.35,
    );
    final hasOutput = state.stdout.isNotEmpty || state.stderr.isNotEmpty;
    final dur = state.duration;
    final body = [
      if (state.errorMessage != null &&
          state.phase == RunPhase.failed &&
          !hasOutput)
        state.errorMessage!,
      if (state.stdout.isNotEmpty) state.stdout,
      if (state.stderr.isNotEmpty) '[stderr]\n${state.stderr}',
    ].join('\n');

    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _phaseLabel,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (state.exitCode != null)
                    Text('exit ${state.exitCode}', style: mono),
                  if (dur != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text('${dur.inMilliseconds} ms', style: mono),
                    ),
                  if (state.phase == RunPhase.starting ||
                      state.phase == RunPhase.running)
                    TextButton(onPressed: onStop, child: const Text('Stop')),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: body.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: body));
                            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(content: Text('Copied')),
                            );
                          },
                  ),
                  if (onClose != null &&
                      (state.phase == RunPhase.finished ||
                          state.phase == RunPhase.failed ||
                          state.phase == RunPhase.idle))
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: onClose,
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: SelectableText(
                  body.isEmpty ? '…' : body,
                  style: mono,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
