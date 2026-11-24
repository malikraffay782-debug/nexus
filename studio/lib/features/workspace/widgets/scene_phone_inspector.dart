import 'package:flutter/material.dart';

import '../scene/scene_model.dart';

/// ±15° step for one rotation axis (phone dock scrolls these horizontally).
class SceneRotAxisStep extends StatelessWidget {
  const SceneRotAxisStep({
    super.key,
    required this.scheme,
    required this.label,
    required this.degrees,
    required this.onDelta,
  });

  final ColorScheme scheme;
  final String label;
  final double degrees;
  final void Function(double delta) onDelta;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: scheme.outline)),
          IconButton(
            tooltip: '$label −15°',
            icon: const Icon(Icons.remove, size: 18),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: () => onDelta(-15),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${degrees.round()}°',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: '$label +15°',
            icon: const Icon(Icons.add, size: 18),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: () => onDelta(15),
          ),
        ],
      ),
    );
  }
}

/// Fixed-height bottom inspector for phone layout — never grows into the stage.
class ScenePhoneInspector extends StatelessWidget {
  const ScenePhoneInspector({
    super.key,
    required this.scheme,
    required this.node,
    required this.onBeginPointsEdit,
    required this.onEnablePoints,
    required this.onClearPoints,
    required this.onDelete,
    required this.onSetType,
    required this.onSetColor,
    required this.onNudgeSize,
    required this.onRotateDelta,
  });

  final ColorScheme scheme;
  final SceneNode node;
  final VoidCallback onBeginPointsEdit;
  final VoidCallback onEnablePoints;
  final VoidCallback onClearPoints;
  final VoidCallback onDelete;
  final ValueChanged<String> onSetType;
  final ValueChanged<int> onSetColor;
  final void Function({required double dw, required double dh}) onNudgeSize;
  final void Function(String axis, double delta) onRotateDelta;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final screenH = MediaQuery.sizeOf(context).height;
    final inspectorH = screenH < 420 ? 120.0 : (screenH < 560 ? 140.0 : 158.0);
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
      elevation: 4,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: inspectorH,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, screenH < 420 ? 4 : 8, 8, 6),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        n.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${n.x.round()},${n.y.round()} · ${n.w.round()}×${n.h.round()}',
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                    if (n.type != SceneNodeTypes.camera) ...[
                      const SizedBox(width: 4),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        onPressed: n.hasPoints
                            ? () {
                                FocusScope.of(context).unfocus();
                                onBeginPointsEdit();
                              }
                            : () {
                                FocusScope.of(context).unfocus();
                                onEnablePoints();
                              },
                        child: Text(
                          n.hasPoints ? 'Points' : 'Edit points',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (n.hasPoints)
                        TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: onClearPoints,
                          child: const Text('Rect', style: TextStyle(fontSize: 13)),
                        ),
                    ],
                    IconButton(
                      tooltip: 'Delete',
                      icon: Icon(Icons.delete_outline, size: 22, color: scheme.error),
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      onPressed: onDelete,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      for (final t in SceneNodeTypes.all)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(t, style: const TextStyle(fontSize: 12)),
                            selected: n.type == t,
                            onSelected: (_) => onSetType(t),
                          ),
                        ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: ScenePalette.colors.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final c = ScenePalette.colors[i];
                            final sel = n.color == c;
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => onSetColor(c),
                              child: SizedBox(
                                width: 36,
                                height: 36,
                                child: Center(
                                  child: Container(
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(
                                      color: Color(c),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: sel
                                            ? scheme.onSurface
                                            : scheme.outlineVariant,
                                        width: sel ? 2.4 : 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: 'Smaller',
                        icon: const Icon(Icons.remove, size: 22),
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        onPressed: () => onNudgeSize(dw: -8, dh: -8),
                      ),
                      IconButton(
                        tooltip: 'Larger',
                        icon: const Icon(Icons.add, size: 22),
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        onPressed: () => onNudgeSize(dw: 8, dh: 8),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      SceneRotAxisStep(
                        scheme: scheme,
                        label: 'RX',
                        degrees: n.rx,
                        onDelta: (d) => onRotateDelta('rx', d),
                      ),
                      SceneRotAxisStep(
                        scheme: scheme,
                        label: 'RY',
                        degrees: n.ry,
                        onDelta: (d) => onRotateDelta('ry', d),
                      ),
                      SceneRotAxisStep(
                        scheme: scheme,
                        label: 'RZ',
                        degrees: n.rz,
                        onDelta: (d) => onRotateDelta('rz', d),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
