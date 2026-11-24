import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../scene/scene_model.dart';

enum SceneResizeCorner { tl, tr, bl, br }

/// Edit-mode node hit targets + resize/rotate/point handles.
class SceneNodeChrome extends StatelessWidget {
  const SceneNodeChrome({
    super.key,
    required this.node,
    required this.selected,
    required this.editPointIndex,
    required this.poseDrag,
    required this.scaleX,
    required this.scaleY,
    required this.stageW,
    required this.stageH,
    required this.scheme,
    required this.resolveNode,
    required this.onSelect,
    required this.onMove,
    required this.onResize,
    required this.onSpinDegrees,
    required this.onBeginPoseDrag,
    required this.onEndPoseDrag,
    required this.onSelectPoint,
    required this.onMovePoint,
    required this.onAddPoint,
    this.paintBody = false,
  });

  final SceneNode node;
  final bool selected;
  final int? editPointIndex;
  final bool poseDrag;
  final double scaleX;
  final double scaleY;
  final double stageW;
  final double stageH;
  final ColorScheme scheme;
  final SceneNode? Function() resolveNode;
  final ValueChanged<String> onSelect;
  final void Function(String id, double x, double y) onMove;
  final void Function(
    String id, {
    required double w,
    required double h,
    double? x,
    double? y,
    bool lockCenter,
  }) onResize;
  final void Function(String id, double degrees) onSpinDegrees;
  final VoidCallback onBeginPoseDrag;
  final VoidCallback onEndPoseDrag;
  final ValueChanged<int> onSelectPoint;
  final void Function(String id, int index, double sceneX, double sceneY)
      onMovePoint;
  final VoidCallback onAddPoint;
  final bool paintBody;

  @override
  Widget build(BuildContext context) => _marker(node);

  Widget _marker(SceneNode n) {
    final selected = this.selected;
    final isCamera = n.type == SceneNodeTypes.camera;
    final fill = Color(n.color).withValues(alpha: selected ? 0.95 : 0.82);
    // Touch-friendly: ~40dp hit, visible ~20dp.
    const handleVisual = 20.0;
    const handleHit = 40.0;

    // --- Polygon (edit-points) mode ---
    // Layout box matches the unrotated model bounds. Rotate + foreshorten match
    // SceneStagePainter so vertex handles sit on the painted pose.
    if (n.hasPoints) {
      final pts = n.points!;
      final left = (n.x * scaleX).clamp(0.0, stageW);
      final top = (n.y * scaleY).clamp(0.0, stageH);
      final mw = (n.w * scaleX).clamp(8.0, stageW);
      final mh = (n.h * scaleY).clamp(8.0, stageH);
      final squash = _poseSquash(n);

      // Body is drawn by SceneStagePainter; this layer is hit-targets + handles.
      final polyChildren = <Widget>[
        SizedBox(width: mw, height: mh),
      ];

      if (selected) {
        for (var i = 0; i < pts.length; i++) {
          final p = pts[i];
          final px = (p.x - n.x) * scaleX;
          final py = (p.y - n.y) * scaleY;
          final active = editPointIndex == i;
          polyChildren.add(
            Positioned(
              left: px - handleHit / 2,
              top: py - handleHit / 2,
              width: handleHit,
              height: handleHit,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) {
                  onSelectPoint(i);
                },
                onPanUpdate: (details) {
                  // Read current point from doc (avoid stale build closure).
                  double cx = p.x;
                  double cy = p.y;
                  final live = resolveNode();
                  if (live != null &&
                      live.hasPoints &&
                      i < live.points!.length) {
                    cx = live.points![i].x;
                    cy = live.points![i].y;
                  }
                  // Inside rotate + scale transforms: global→local already
                  // undoes pose, so only stage scale maps to model units.
                  final nx = cx + details.delta.dx / scaleX;
                  final ny = cy + details.delta.dy / scaleY;
                  onMovePoint(n.id, i, nx, ny);
                },
                child: Center(
                  child: Container(
                    width: handleVisual,
                    height: handleVisual,
                    decoration: BoxDecoration(
                      color: active ? const Color(0xFF69F0AE) : Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: fill,
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        // Edge midpoints — tap to insert a vertex on that edge.
        for (var i = 0; i < pts.length; i++) {
          final a = pts[i];
          final b = pts[(i + 1) % pts.length];
          final mx = ((a.x + b.x) / 2 - n.x) * scaleX;
          final my = ((a.y + b.y) / 2 - n.y) * scaleY;
          const midHit = 28.0;
          const midVisual = 14.0;
          final edgeIndex = i;
          polyChildren.add(
            Positioned(
              left: mx - midHit / 2,
              top: my - midHit / 2,
              width: midHit,
              height: midHit,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  onSelectPoint(edgeIndex);
                  onAddPoint();
                },
                child: Center(
                  child: Container(
                    width: midVisual,
                    height: midVisual,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.surface.withValues(alpha: 0.9),
                      shape: BoxShape.circle,
                      border: Border.all(color: fill, width: 1.5),
                    ),
                    child: Icon(Icons.add, size: 10, color: fill),
                  ),
                ),
              ),
            ),
          );
        }
      }

      final stackChildren = <Widget>[
        Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(squash.$1, squash.$2, 1),
          child: SizedBox(
            width: mw,
            height: mh,
            child: Stack(
              clipBehavior: Clip.none,
              children: polyChildren,
            ),
          ),
        ),
        if (selected)
          ..._rotateHandle(
            n: n,
            boxW: mw,
            boxH: mh,
            fill: fill,
            visual: handleVisual,
            hit: handleHit,
          ),
      ];

      return Positioned(
        left: left,
        top: top,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelect(n.id),
          onPanUpdate: (details) {
            if (poseDrag) return;
            SceneNode? cur = resolveNode();
            if (cur == null) return;
            // Outside rotate transform — delta stays in stage space.
            final newX = cur.x + details.delta.dx / scaleX;
            final newY = cur.y + details.delta.dy / scaleY;
            onMove(n.id, newX, newY);
          },
          child: Transform.rotate(
            angle: n.rz * math.pi / 180.0,
            alignment: Alignment.center,
            child: SizedBox(
              width: mw,
              height: mh,
              child: Stack(
                clipBehavior: Clip.none,
                children: stackChildren,
              ),
            ),
          ),
        ),
      );
    }

    // --- Rect mode (default) ---
    // Layout box matches the unrotated model. Rotate + foreshorten are the
    // same as SceneStagePainter so the grab shape matches the paint.
    final mw = math.max(n.w * scaleX, 1.0);
    final mh = math.max(n.h * scaleY, 1.0);
    final left = n.x * scaleX;
    final top = n.y * scaleY;
    final squash = _poseSquash(n);

    Widget body = paintBody
        ? Container(
            width: mw,
            height: mh,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(isCamera ? 20 : 6),
              border: Border.all(
                color: selected ? Colors.white : fill.withValues(alpha: 1),
                width: selected ? 2.5 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: fill.withValues(alpha: 0.45),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              isCamera ? Icons.videocam : Icons.square_rounded,
              size: (mw < 28 || mh < 28) ? 12 : 18,
              color: Colors.white.withValues(alpha: 0.95),
            ),
          )
        : SizedBox(width: mw, height: mh);

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: () => onSelect(n.id),
        onPanUpdate: (details) {
          if (poseDrag) return;
          SceneNode? cur = resolveNode();
          if (cur == null) return;
          // Parent of the rotate transform — delta stays in stage space.
          final newX = cur.x + details.delta.dx / scaleX;
          final newY = cur.y + details.delta.dy / scaleY;
          onMove(n.id, newX, newY);
        },
        child: Transform.rotate(
          angle: n.rz * math.pi / 180.0,
          alignment: Alignment.center,
          child: SizedBox(
            width: mw,
            height: mh,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.diagonal3Values(squash.$1, squash.$2, 1),
                  child: body,
                ),
                if (selected) ...[
                  for (final corner in SceneResizeCorner.values)
                    _resizeHandle(
                      n: n,
                      scaleX: scaleX,
                      scaleY: scaleY,
                      boxW: mw,
                      boxH: mh,
                      fill: fill,
                      visual: handleVisual,
                      hit: handleHit,
                      corner: corner,
                    ),
                  ..._rotateHandle(
                    n: n,
                    boxW: mw,
                    boxH: mh,
                    fill: fill,
                    visual: handleVisual,
                    hit: handleHit,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pitch/yaw foreshorten. Shared with [SceneStagePainter] via [SceneNode.foreshorten].
  (double, double) _poseSquash(SceneNode n) {
    if (n.isCamera) return (1.0, 1.0);
    return SceneNode.foreshorten(n.rx, n.ry);
  }

  bool _hasPose(SceneNode n) =>
      n.rx.abs() > 0.01 || n.ry.abs() > 0.01 || n.rz.abs() > 0.01;


  /// Point the orbit handle at [globalPointer]. Absolute angle, so it does not
  /// depend on whether drag delta is local or screen space.
  void _spinNodeTo(String id, Offset globalPointer, Offset globalCenter) {
    final v = globalPointer - globalCenter;
    if (v.distanceSquared < 36) return;
    final deg = (math.atan2(v.dy, v.dx) + math.pi / 2) * 180.0 / math.pi;
    onSpinDegrees(id, deg);
  }

  Widget _resizeHandle({
    required SceneNode n,
    required double scaleX,
    required double scaleY,
    required double boxW,
    required double boxH,
    required Color fill,
    required double visual,
    required double hit,
    required SceneResizeCorner corner,
  }) {
    final squash = _poseSquash(n);
    final hx = boxW / 2 * squash.$1;
    final hy = boxH / 2 * squash.$2;
    final cx = boxW / 2;
    final cy = boxH / 2;
    // Sit on the foreshortened corner (outside the scale transform) so the
    // 40dp hit does not collapse when pitch/yaw squash the rect.
    late final double cornerX;
    late final double cornerY;
    switch (corner) {
      case SceneResizeCorner.tl:
        cornerX = cx - hx + 2;
        cornerY = cy - hy + 2;
        break;
      case SceneResizeCorner.tr:
        cornerX = cx + hx - 2;
        cornerY = cy - hy + 2;
        break;
      case SceneResizeCorner.bl:
        cornerX = cx - hx + 2;
        cornerY = cy + hy - 2;
        break;
      case SceneResizeCorner.br:
        cornerX = cx + hx - 2;
        cornerY = cy + hy - 2;
        break;
    }
    return Positioned(
      left: cornerX - hit / 2,
      top: cornerY - hit / 2,
      width: hit,
      height: hit,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onBeginPoseDrag(),
        onPanEnd: (_) => onEndPoseDrag(),
        onPanCancel: onEndPoseDrag,
        onPanUpdate: (details) {
          SceneNode? cur = resolveNode();
          if (cur == null) return;
          // Delta is already in model-local axes (parent Transform.rotate
          // undoes roll). Divide by foreshorten so the corner tracks the finger.
          final sq = _poseSquash(cur);
          final dx = details.delta.dx / (scaleX * sq.$1);
          final dy = details.delta.dy / (scaleY * sq.$2);
          final lock = _hasPose(cur);
          switch (corner) {
            case SceneResizeCorner.br:
              onResize(
                n.id,
                w: cur.w + dx,
                h: cur.h + dy,
                lockCenter: lock,
              );
              break;
            case SceneResizeCorner.bl:
              onResize(
                n.id,
                w: cur.w - dx,
                h: cur.h + dy,
                x: cur.x + dx,
                lockCenter: lock,
              );
              break;
            case SceneResizeCorner.tr:
              onResize(
                n.id,
                w: cur.w + dx,
                h: cur.h - dy,
                y: cur.y + dy,
                lockCenter: lock,
              );
              break;
            case SceneResizeCorner.tl:
              onResize(
                n.id,
                w: cur.w - dx,
                h: cur.h - dy,
                x: cur.x + dx,
                y: cur.y + dy,
                lockCenter: lock,
              );
              break;
          }
        },
        child: Center(
          child: Container(
            width: visual,
            height: visual,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: fill, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Amber orbit handle above the visual top edge. Rolls with [Transform.rotate].
  /// Direct [Positioned] children — a nested stack would be 0×0 and drop hits.
  List<Widget> _rotateHandle({
    required SceneNode n,
    required double boxW,
    required double boxH,
    required Color fill,
    required double visual,
    required double hit,
  }) {
    final sy = _poseSquash(n).$2;
    final orbit = boxH / 2 * sy + 22;
    return [
      Positioned(
        left: boxW / 2 - 1,
        top: boxH / 2 - orbit,
        width: 2,
        height: 22,
        child: const IgnorePointer(
          child: ColoredBox(color: Color(0xFFFFC107)),
        ),
      ),
      Positioned(
        left: boxW / 2 - hit / 2,
        top: boxH / 2 - orbit - hit / 2,
        width: hit,
        height: hit,
        child: Builder(
          builder: (handleContext) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => onBeginPoseDrag(),
              onPanEnd: (_) => onEndPoseDrag(),
              onPanCancel: onEndPoseDrag,
              onPanUpdate: (details) {
                final box = handleContext.findRenderObject() as RenderBox?;
                if (box == null || !box.hasSize) return;
                // Layout +Y from the handle center is the node center.
                final center = box.localToGlobal(
                  Offset(hit / 2, hit / 2 + orbit),
                );
                _spinNodeTo(n.id, details.globalPosition, center);
              },
              child: Center(
                child: Container(
                  width: visual,
                  height: visual,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFC107),
                    shape: BoxShape.circle,
                    border: Border.all(color: fill, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.rotate_right,
                    size: 14,
                    color: Colors.black,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ];
  }
}
