import 'package:flutter/material.dart';

import '../scene/scene_model.dart';

/// Large video-editor style pad: left tool rail + full swipe surface.
/// Height scales down in landscape / short viewports so the stage is not buried.
class ScenePointsPad extends StatelessWidget {
  const ScenePointsPad({
    super.key,
    required this.scheme,
    required this.node,
    required this.editIndex,
    required this.onDone,
    required this.onAddPoint,
    required this.onRemovePoint,
    required this.onSelectIndex,
    required this.onNudge,
  });

  final ColorScheme scheme;
  final SceneNode node;
  final int editIndex;
  final VoidCallback onDone;
  final VoidCallback onAddPoint;
  final VoidCallback onRemovePoint;
  final ValueChanged<int> onSelectIndex;
  final void Function({required double dx, required double dy}) onNudge;

  @override
  Widget build(BuildContext context) {
    final pts = node.points;
    if (pts == null || pts.length < 3) return const SizedBox.shrink();
    if (editIndex < 0 || editIndex >= pts.length) {
      return const SizedBox.shrink();
    }
    final p = pts[editIndex];
    final screenH = MediaQuery.sizeOf(context).height;
    final padH = screenH < 420
        ? 180.0
        : (screenH < 560 ? 240.0 : 320.0);
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.98),
      elevation: 8,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: padH,
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(Icons.control_camera,
                          size: 20, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Edit Points  ·  P${editIndex + 1}/${pts.length}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${p.x.round()}, ${p.y.round()}',
                        style: TextStyle(fontSize: 13, color: scheme.outline),
                      ),
                      const Spacer(),
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          onDone();
                        },
                        child: const Text(
                          'Done',
                          style: TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Column(
                        children: [
                          const SizedBox(height: 6),
                          IconButton(
                            tooltip: 'Add vertex on edge',
                            icon: const Icon(Icons.add_circle_outline, size: 24),
                            constraints: const BoxConstraints(
                                minWidth: 48, minHeight: 44),
                            onPressed: onAddPoint,
                          ),
                          IconButton(
                            tooltip: 'Remove vertex',
                            icon:
                                const Icon(Icons.remove_circle_outline, size: 24),
                            constraints: const BoxConstraints(
                                minWidth: 48, minHeight: 44),
                            onPressed: pts.length > 3 ? onRemovePoint : null,
                          ),
                          const Divider(height: 12),
                          Expanded(
                            child: ListView.builder(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              itemCount: pts.length,
                              itemBuilder: (context, i) {
                                final sel = i == editIndex;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Material(
                                    color: sel
                                        ? scheme.primaryContainer
                                        : scheme.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(10),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      onTap: () => onSelectIndex(i),
                                      child: SizedBox(
                                        height: 36,
                                        child: Center(
                                          child: Text(
                                            'P${i + 1}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: sel
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: ColoredBox(
                        color: scheme.surface.withValues(alpha: 0.92),
                        child: Stack(
                          fit: StackFit.expand,
                          alignment: Alignment.center,
                          children: [
                            Positioned(
                              left: 12,
                              top: 10,
                              child: Icon(
                                Icons.crop_free,
                                size: 18,
                                color: scheme.outline.withValues(alpha: 0.35),
                              ),
                            ),
                            Positioned(
                              right: 12,
                              bottom: 10,
                              child: Icon(
                                Icons.crop_free,
                                size: 18,
                                color: scheme.outline.withValues(alpha: 0.35),
                              ),
                            ),
                            IgnorePointer(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.open_with,
                                    size: 40,
                                    color: scheme.primary
                                        .withValues(alpha: 0.45),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Swipe here to move the point',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                      color: scheme.onSurface
                                          .withValues(alpha: 0.75),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Or drag handles on the stage',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: scheme.outline,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Positioned.fill(
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerMove: (e) {
                                  const sens = 1.6;
                                  onNudge(
                                    dx: e.delta.dx * sens,
                                    dy: e.delta.dy * sens,
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
