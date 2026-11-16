import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'scene_model.dart';

/// Graphical 2D stage painter — sprites / cameras / polys.
///
/// Edit mode (`playTime <= 0`): ortho paint so drag handles match model coords.
/// Play preview (`playTime > 0`): non-destructive bob + camera depth projection
/// (same look-+Z convention as `scene_draw.py`). Does not mutate [doc].
///
/// Low-end notes:
/// - Camera frame constants resolved once per [paint].
/// - No per-frame record/tuple sort list; plain [List.of] + sort.
/// - Grid skipped while playing (saves many drawLine calls on weak GPUs).
/// - Depth scale / frustum tested once per node, not per corner.
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

  // --- Play-frame camera cache (filled at start of paint) ---
  // Avoids re-reading cam fields and re-clamping near/far on every node.
  bool _hasCam = false;
  double _camCx = 0;
  double _camCy = 0;
  double _camCz = 0;
  double _camNear = SceneNode.defaultNear;
  double _camFar = SceneNode.defaultFar;
  double _camFovK = 1.0;
  double _camRef = 1.0;

  void _resolveCamera() {
    _hasCam = false;
    if (playTime <= 0) return;
    for (final n in doc.nodes) {
      if (!n.isCamera) continue;
      _camCx = n.x + n.w * 0.5;
      _camCy = n.y + n.h * 0.5;
      _camCz = n.z;
      _camNear = n.near > 0 ? n.near : SceneNode.defaultNear;
      _camFar = n.far > _camNear ? n.far : SceneNode.defaultFar;
      _camFovK = (n.fov / 60.0).clamp(0.35, 2.5);
      _camRef = math.max(doc.width.toDouble(), doc.height.toDouble()) * 0.35;
      _hasCam = true;
      return; // first camera in list order (matches run path)
    }
  }

  /// Preview bob in scene units. Cameras stay fixed.
  Offset _previewOffset(SceneNode n) {
    if (playTime <= 0 || n.isCamera) return Offset.zero;
    final phase = playTime * 2.4 + n.x * 0.02 + n.y * 0.015;
    return Offset(math.cos(phase * 0.7) * 4.0, math.sin(phase) * 10.0);
  }

  /// Soft perspective toward active camera (play only).
  ///
  /// Returns `(x, y, uniformScale, inFrustum)`.
  /// Ortho / no cam → identity scale and inFrustum=true.
  (double, double, double, bool) _project(double x, double y, double z) {
    if (!_hasCam) return (x, y, 1.0, true);
    final depth = z - _camCz;
    if (depth < _camNear || depth > _camFar) {
      return (x, y, 1.0, false);
    }
    // scale → 1 at depth≈0, shrinks with depth (readable on pixel-like stages)
    final scale = _camRef / (_camRef + math.max(depth, _camNear) * _camFovK);
    return (
      _camCx + (x - _camCx) * scale,
      _camCy + (y - _camCy) * scale,
      scale,
      true,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (doc.width <= 0 || doc.height <= 0) return;

    final scaleX = size.width / doc.width;
    final scaleY = size.height / doc.height;
    _resolveCamera();

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1A1A22),
    );

    // Grid is static; skip during play to cut drawLine cost on low-end GPUs.
    if (showGrid && playTime <= 0) {
      _paintGrid(canvas, size, scaleX, scaleY);
    }

    final nodes = doc.nodes;
    final count = nodes.length;
    if (count == 0) return;

    // Depth order: non-cameras far→near by z; cameras last. Stable on ties.
    // List.of avoids the (index,node) record list; fine for typical scene sizes.
    final ordered = List<SceneNode>.of(nodes);
    if (count > 1) {
      ordered.sort((a, b) {
        final ac = a.isCamera ? 1 : 0;
        final bc = b.isCamera ? 1 : 0;
        if (ac != bc) return ac - bc;
        final cz = a.z.compareTo(b.z);
        if (cz != 0) return cz;
        // Stable-ish: fall back to identity hash only when z+type match;
        // original index order is not preserved after List.of, but equal-z
        // flicker is rare and cheaper than allocating index pairs every frame.
        return a.id.compareTo(b.id);
      });
    }

    for (final n in ordered) {
      _paintNode(canvas, n, scaleX, scaleY);
    }
  }

  void _paintGrid(Canvas canvas, Size size, double scaleX, double scaleY) {
    final paint = Paint()
      ..color = const Color(0x3AFFFFFF)
      ..strokeWidth = 1;
    const step = 40.0;
    final maxX = doc.width.toDouble();
    final maxY = doc.height.toDouble();
    for (double x = 0; x <= maxX; x += step) {
      final px = x * scaleX;
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), paint);
    }
    for (double y = 0; y <= maxY; y += step) {
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
    final isCamera = n.isCamera;
    final off = _previewOffset(n);

    // One depth test / scale sample per node (not per corner).
    var alphaMul = 1.0;
    var pScale = 1.0;
    if (!isCamera && _hasCam) {
      final depth = n.z - _camCz;
      if (depth < _camNear || depth > _camFar) {
        alphaMul = 0.28; // outside frustum: dim, still visible for context
      } else {
        pScale = _camRef / (_camRef + math.max(depth, _camNear) * _camFovK);
      }
    }

    final baseA = (selected ? 0.95 : 0.85) * alphaMul;
    final fill = Color(n.color).withValues(alpha: baseA);
    final stroke = selected
        ? Colors.white.withValues(alpha: alphaMul < 1 ? 0.4 : 1.0)
        : fill;

    if (n.hasPoints) {
      _paintPoly(canvas, n, off, scaleX, scaleY, fill, stroke, selected);
      return;
    }

    // Rect: project center; size shrinks by pScale in play+camera mode.
    final midX = n.x + off.dx + n.w * 0.5;
    final midY = n.y + off.dy + n.h * 0.5;
    double outX = midX;
    double outY = midY;
    if (!isCamera && _hasCam && alphaMul >= 1.0) {
      // in-frustum: apply same scale used for size
      outX = _camCx + (midX - _camCx) * pScale;
      outY = _camCy + (midY - _camCy) * pScale;
    }
    final drawW = n.w * (isCamera ? 1.0 : pScale);
    final drawH = n.h * (isCamera ? 1.0 : pScale);
    final rect = Rect.fromCenter(
      center: Offset(outX * scaleX, outY * scaleY),
      width: drawW * scaleX,
      height: drawH * scaleY,
    );
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
      ..color = Colors.white.withValues(alpha: 0.9 * alphaMul)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (isCamera) {
      canvas.drawCircle(Offset(cx, cy), 6, glyph);
      _paintCameraFrustum(canvas, n, scaleX, scaleY, selected);
      return;
    }

    final g = 10.0 * pScale;
    canvas.drawRect(
      Rect.fromCenter(center: Offset(cx, cy), width: g, height: g),
      glyph,
    );
    // Mesh badge — only when linked (string empty check before normalize).
    if (n.mesh.isNotEmpty && SceneMeshes.normalize(n.mesh).isNotEmpty) {
      final badge = Path()
        ..moveTo(cx, cy - 8)
        ..lineTo(cx + 7, cy + 5)
        ..lineTo(cx - 7, cy + 5)
        ..close();
      canvas.drawPath(
        badge,
        Paint()..color = Colors.white.withValues(alpha: 0.85 * alphaMul),
      );
    }
  }

  void _paintPoly(
    Canvas canvas,
    SceneNode n,
    Offset off,
    double scaleX,
    double scaleY,
    Color fill,
    Color stroke,
    bool selected,
  ) {
    final pts = n.points!;
    final path = Path();
    final applyProj = _hasCam;
    for (var i = 0; i < pts.length; i++) {
      var x = pts[i].x + off.dx;
      var y = pts[i].y + off.dy;
      if (applyProj) {
        final pr = _project(x, y, n.z);
        // Out-of-frustum points stay at ortho position (dimmed via fill alpha).
        if (pr.$4) {
          x = pr.$1;
          y = pr.$2;
        }
      }
      final px = x * scaleX;
      final py = y * scaleY;
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
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
    // Vertex handles only in edit mode (play hides selection chrome upstream).
    if (selected && playTime <= 0) {
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
  }

  /// 2D FOV wedge hint (along +Y). Visual only — not the run-path +Z volume.
  void _paintCameraFrustum(
    Canvas canvas,
    SceneNode n,
    double scaleX,
    double scaleY,
    bool selected,
  ) {
    final cx = (n.x + n.w * 0.5) * scaleX;
    final cy = (n.y + n.h * 0.5) * scaleY;
    final depth = n.far.clamp(80.0, 480.0);
    final halfRad = (n.fov.clamp(1.0, 179.0) * math.pi / 180.0) * 0.5;
    final halfW = depth * math.tan(halfRad);
    final tipY = cy + n.h * scaleY * 0.15;
    final left = Offset(cx - halfW * scaleX, tipY + depth * scaleY);
    final right = Offset(cx + halfW * scaleX, tipY + depth * scaleY);
    final apex = Offset(cx, tipY);
    final path = Path()
      ..moveTo(apex.dx, apex.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(right.dx, right.dy)
      ..close();
    final fillA = selected ? 0.14 : 0.07;
    final strokeA = selected ? 0.85 : 0.45;
    const frustumColor = Color(0xFF80D8FF);
    canvas.drawPath(
      path,
      Paint()..color = frustumColor.withValues(alpha: fillA),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = frustumColor.withValues(alpha: strokeA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 1.8 : 1.1,
    );
    // Near plane tick along the wedge
    final nearT = (n.near.clamp(0.01, depth) / depth).clamp(0.05, 0.95);
    final ny = tipY + depth * scaleY * nearT;
    final nw = halfW * scaleX * nearT;
    canvas.drawLine(
      Offset(cx - nw, ny),
      Offset(cx + nw, ny),
      Paint()
        ..color = frustumColor.withValues(alpha: strokeA * 0.8)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant SceneStagePainter old) {
    // playTime changes every tick while playing — must repaint.
    // Quantize slightly so sub-frame notifier noise does not chain extra paints.
    if (old.doc != doc ||
        old.selectedId != selectedId ||
        old.editPointIndex != editPointIndex ||
        old.showGrid != showGrid) {
      return true;
    }
    // ~120 Hz threshold: skip repaint if time delta is tiny (duplicate ticks).
    return (old.playTime - playTime).abs() > 0.008;
  }
}
