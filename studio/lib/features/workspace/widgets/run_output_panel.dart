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
        RunPhase.cancelled => state.errorMessage ?? 'Stopped',
      };

  /// Fixed height budget so parent Column never overflows when the soft
  /// keyboard or landscape leaves little vertical space.
  ///
  /// Landscape phones often have usable height ~360–420 after system bars +
  /// AppBar + TabBar. Keep the panel small enough that Scene/Code still has
  /// a usable canvas.
  static double heightFor(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final viewInsets = MediaQuery.viewInsetsOf(context).bottom;
    // Prefer the space that remains after keyboard when it is open.
    final available = (h - viewInsets).clamp(0.0, h);
    if (available < 380) return 110;
    if (available < 500) return 140;
    if (available < 640) return 170;
    return 200;
  }

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
          (state.phase == RunPhase.failed ||
              state.phase == RunPhase.cancelled) &&
          !hasOutput)
        state.errorMessage!,
      if (state.stdout.isNotEmpty) state.stdout,
      if (state.stderr.isNotEmpty) '[stderr]\n${state.stderr}',
    ].join('\n');

    // Panel shows only a tail — full body kept for Copy (2 GB layout cost).
    const panelMaxChars = 32000;
    final displayBody = body.length <= panelMaxChars
        ? body
        : '…[earlier output truncated]
' + body.substring(body.length - panelMaxChars);

    final panelH = heightFor(context);
    final compact = panelH <= 140;

    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: panelH,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(12, compact ? 4 : 6, 4, compact ? 2 : 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _phaseLabel,
                      style: compact
                          ? theme.textTheme.labelLarge
                          : theme.textTheme.titleSmall,
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
                    TextButton(
                      onPressed: onStop,
                      style: compact
                          ? TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            )
                          : null,
                      child: const Text('Stop'),
                    ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: Icon(Icons.copy, size: compact ? 16 : 18),
                    visualDensity: VisualDensity.compact,
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
                          state.phase == RunPhase.cancelled ||
                          state.phase == RunPhase.idle))
                    IconButton(
                      tooltip: 'Close',
                      icon: Icon(Icons.close, size: compact ? 16 : 18),
                      visualDensity: VisualDensity.compact,
                      onPressed: onClose,
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(12, compact ? 4 : 8, 12, compact ? 8 : 12),
                child: SelectableText(
                  displayBody.isEmpty ? '…' : displayBody,
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
