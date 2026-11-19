import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'scene_model.dart';
import 'scene_project.dart';

/// Graphical 2D stage painter — sprites / cameras / polys.
///
/// Edit mode (`playTime <= 0`): ortho paint so drag handles match model coords.
/// Play preview (`playTime > 0`): non-destructive bob + camera projection
/// via [SceneProject] (default [SceneProjectMode.soft] for low-end).
/// Does not mutate [doc].
///
/// Low-end notes:
/// - [SceneCamFrame] resolved once per [paint].
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
    this.projectMode = SceneProjectMode.soft,
  });

  final SceneDoc doc;
  final String? selectedId;
  final int? editPointIndex;
  final bool showGrid;
  final double playTime;
  /// Soft = default low-end; ndc = Unity-style space (opt-in).
  final SceneProjectMode projectMode;

  /// Play-frame camera (null in edit mode or when no camera node).
  SceneCamFrame? _cam;
  /// Cached P×V for NDC mode (once per paint).
  SceneMat4? _viewProjection;

  /// Preview bob in scene units. Cameras stay fixed.
  Offset _previewOffset(SceneNode n) {
    if (playTime <= 0 || n.isCamera) return Offset.zero;
    final phase = playTime * 2.4 + n.x * 0.02 + n.y * 0.015;
    return Offset(math.cos(phase * 0.7) * 4.0, math.sin(phase) * 10.0);
  }

  /// Project stage point; identity when no cam / edit mode.
  SceneProjected _project(double x, double y, double z) {
    final cam = _cam;
    if (cam == null) {
      return SceneProjected(x: x, y: y, scale: 1, visible: true);
    }
    return SceneProject.project(
      cam,
      x,
      y,
      z,
      mode: projectMode,
      viewProjection: _viewProjection,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (doc.width <= 0 || doc.height <= 0) return;

    final scaleX = size.width / doc.width;
    final scaleY = size.height / doc.height;
    _cam = playTime > 0
        ? SceneCamFrame.fromNodes(
            doc.nodes,
            stageW: doc.width.toDouble(),
            stageH: doc.height.toDouble(),
          )
        : null;
    _viewProjection = (_cam != null && projectMode == SceneProjectMode.ndc)
        ? _cam!.viewProjectionMatrix()
        : null;

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
    final cam = _cam;

    // Play + camera: AABB (rect or poly bounds @ z) — skip if fully outside.
    // Project center for draw pose when visible. Edit (no cam) → always draw.
    var boundX = n.x + off.dx;
    var boundY = n.y + off.dy;
    var boundW = n.w;
    var boundH = n.h;
    if (n.hasPoints) {
      final pts = n.points!;
      var minX = pts.first.x;
      var maxX = minX;
      var minY = pts.first.y;
      var maxY = minY;
      for (final p in pts) {
        if (p.x < minX) minX = p.x;
        if (p.x > maxX) maxX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.y > maxY) maxY = p.y;
      }
      boundX = minX + off.dx;
      boundY = minY + off.dy;
      boundW = (maxX - minX).clamp(1.0, double.infinity);
      boundH = (maxY - minY).clamp(1.0, double.infinity);
    }
    final midX = boundX + boundW * 0.5;
    final midY = boundY + boundH * 0.5;
    var pScale = 1.0;
    var outX = midX;
    var outY = midY;
    if (!isCamera && cam != null) {
      final visible = SceneProject.aabbVisible(
        cam,
        boundX,
        boundY,
        boundW,
        boundH,
        n.z,
        zDepth: n.zDepth,
        mode: projectMode,
        viewProjection: _viewProjection,
      );
      if (!visible) return;
      final pr = _project(midX, midY, n.z);
      // Center may be outside while a corner is inside — still draw at
      // projected center if possible; else keep stage center.
      if (pr.visible) {
        pScale = pr.scale;
        outX = pr.x;
        outY = pr.y;
      } else {
        pScale = SceneProject.depthScale(cam, cam.depthOf(n.z));
      }
    }

    final fill = Color(n.color).withValues(alpha: selected ? 0.95 : 0.85);
    final stroke = selected ? Colors.white : fill;

    if (n.hasPoints) {
      _paintPoly(canvas, n, off, scaleX, scaleY, fill, stroke, selected);
      return;
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
      ..color = Colors.white.withValues(alpha: 0.9)
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
    if (n.mesh.isNotEmpty && SceneMeshes.normalize(n.mesh).isNotEmpty) {
      final badge = Path()
        ..moveTo(cx, cy - 8)
        ..lineTo(cx + 7, cy + 5)
        ..lineTo(cx - 7, cy + 5)
        ..close();
      canvas.drawPath(
        badge,
        Paint()..color = Colors.white.withValues(alpha: 0.85),
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
    final applyProj = _cam != null;
    for (var i = 0; i < pts.length; i++) {
      var x = pts[i].x + off.dx;
      var y = pts[i].y + off.dy;
      if (applyProj) {
        final pr = _project(x, y, n.z);
        // Out-of-frustum points stay at ortho position (dimmed via fill alpha).
        if (pr.visible) {
          x = pr.x;
          y = pr.y;
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
        old.showGrid != showGrid ||
        old.projectMode != projectMode) {
      return true;
    }
    // ~120 Hz threshold: skip repaint if time delta is tiny (duplicate ticks).
    return (old.playTime - playTime).abs() > 0.008;
  }
}
