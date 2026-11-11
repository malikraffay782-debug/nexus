import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'scene_model.dart';

/// Graphical 2D stage painter — draws scene nodes (sprites / cameras / polys).
/// Used by the editor canvas and the play/preview loop.
///
/// [playTime] > 0 enables a non-destructive preview motion (does not mutate [doc]).
class SceneStagePainter extends CustomPainter {
  SceneStagePainter({
    required this.doc,
    this.selectedId,
    this.editPointIndex,
    this.showGrid = true,
    this.playTime = 0.0,
  });

  final SceneDoc doc;
  final String? selectedId;
  final int? editPointIndex;
  final bool showGrid;
  final double playTime;

  /// Preview-only offset in scene space (sprites / polys; cameras fixed).
  Offset _previewOffset(SceneNode n) {
    if (playTime <= 0 || n.type == SceneNodeTypes.camera) {
      return Offset.zero;
    }
    // Gentle bob — proves the 2D tick is running without writing the model.
    final phase = playTime * 2.4 + n.x * 0.02 + n.y * 0.015;
    final dy = math.sin(phase) * 10.0;
    final dx = math.cos(phase * 0.7) * 4.0;
    return Offset(dx, dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (doc.width <= 0 || doc.height <= 0) return;
    final scaleX = size.width / doc.width;
    final scaleY = size.height / doc.height;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1A1A22),
    );

    if (showGrid) {
      _paintGrid(canvas, size, scaleX, scaleY);
    }

    // Paint order = list order (last on top).
    for (final n in doc.nodes) {
      _paintNode(canvas, n, scaleX, scaleY);
    }
  }

  void _paintGrid(Canvas canvas, Size size, double scaleX, double scaleY) {
    final paint = Paint()
      ..color = const Color(0x3AFFFFFF)
      ..strokeWidth = 1;
    const step = 40.0;
    for (double x = 0; x <= doc.width; x += step) {
      final px = x * scaleX;
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), paint);
    }
    for (double y = 0; y <= doc.height; y += step) {
      final py = y * scaleY;
      canvas.drawLine(Offset(0, py), Offset(size.width, py), paint);
    }
  }

  void _paintNode(
    Canvas canvas,
    SceneNode n,
    double scaleX,
    double scaleY,
  ) {
    final selected = n.id == selectedId;
    final fill = Color(n.color).withValues(alpha: selected ? 0.95 : 0.85);
    final stroke = selected ? Colors.white : fill.withValues(alpha: 1);
    final off = _previewOffset(n);

    if (n.hasPoints) {
      final path = Path();
      final pts = n.points!;
      path.moveTo(
        (pts.first.x + off.dx) * scaleX,
        (pts.first.y + off.dy) * scaleY,
      );
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(
          (pts[i].x + off.dx) * scaleX,
          (pts[i].y + off.dy) * scaleY,
        );
      }
      path.close();
      canvas.drawPath(path, Paint()..color = fill);
      canvas.drawPath(
        path,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2.5 : 1.2,
      );
      if (selected) {
        for (var i = 0; i < pts.length; i++) {
          final active = editPointIndex == i;
          canvas.drawCircle(
            Offset(
              (pts[i].x + off.dx) * scaleX,
              (pts[i].y + off.dy) * scaleY,
            ),
            active ? 7 : 5,
            Paint()
              ..color = active ? const Color(0xFF69F0AE) : Colors.white,
          );
        }
      }
      return;
    }

    final rect = Rect.fromLTWH(
      (n.x + off.dx) * scaleX,
      (n.y + off.dy) * scaleY,
      n.w * scaleX,
      n.h * scaleY,
    );
    final isCamera = n.type == SceneNodeTypes.camera;
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(isCamera ? 20 : 6),
    );
    canvas.drawRRect(rrect, Paint()..color = fill);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.5 : 1.2,
    );

    final cx = rect.center.dx;
    final cy = rect.center.dy;
    final glyph = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (isCamera) {
      canvas.drawCircle(Offset(cx, cy), 6, glyph);
    } else {
      canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: 10, height: 10),
        glyph,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SceneStagePainter old) {
    return old.doc != doc ||
        old.selectedId != selectedId ||
        old.editPointIndex != editPointIndex ||
        old.showGrid != showGrid ||
        old.playTime != playTime;
  }
}
