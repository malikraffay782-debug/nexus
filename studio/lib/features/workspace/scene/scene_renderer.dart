import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'scene_model.dart';
import 'scene_play_state.dart';
import 'scene_project.dart';

/// Graphical 2D stage painter — sprites / cameras / polys.
///
/// Edit mode (`playTime <= 0`): ortho paint so drag handles match model coords.
/// Play preview (`playTime > 0`): draws [playState] poses + camera projection
/// via [SceneProject] (default [SceneProjectMode.soft] for low-end).
/// Simulation lives in [ScenePlayState]; this painter only draws.
/// Active camera eye XY follows Player runtime center when present.
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
    this.playState,
  });

  final SceneDoc doc;
  final String? selectedId;
  final int? editPointIndex;
  final bool showGrid;
  final double playTime;
  /// Soft = default low-end; ndc = Unity-style space (opt-in).
  final SceneProjectMode projectMode;
  /// Runtime poses from [ScenePlayController] (null in edit mode).
  final ScenePlayState? playState;

  // Reused paints — avoid per-frame Paint() on low-end (B11).
  static final Paint _bgPaint = _bgPaint;
  static final Paint _gridPaint = Paint()
    ..color = const Color(0x3AFFFFFF)
    ..strokeWidth = 1;

  /// Play-frame camera (null in edit mode or when no camera node).
  SceneCamFrame? _cam;
  /// Cached P×V for NDC mode (once per paint).
  SceneMat4? _viewProjection;

  /// Runtime offset from [playState] (no simulation here).
  Offset _previewOffset(SceneNode n) {
    if (playTime <= 0 || n.isCamera) return Offset.zero;
    final state = playState;
    if (state == null) return Offset.zero;
    return state.runtimeOffset(n);
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
    // Play: selected camera (if any) else first; then XY-follow Player.
    SceneCamFrame? cam;
    if (playTime > 0) {
      cam = SceneCamFrame.fromNodes(
        doc.nodes,
        stageW: doc.width.toDouble(),
        stageH: doc.height.toDouble(),
        preferredId: selectedId,
      );
      if (cam != null) {
        final center = playState?.playerCenter(doc);
        if (center != null) {
          // Follow Player runtime center; lens/z stay on camera node.
          cam = cam.withEyeXy(center.dx, center.dy);
        }
      }
    }
    _cam = cam;
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
    final paint = _gridPaint;
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
      _paintPoly(
        canvas,
        n,
        off,
        scaleX,
        scaleY,
        fill,
        stroke,
        selected,
        pivotX: outX,
        pivotY: outY,
        midX: midX,
        midY: midY,
        depthScale: isCamera ? 1.0 : pScale,
      );
      return;
    }
    final drawW = n.w * (isCamera ? 1.0 : pScale);
    final drawH = n.h * (isCamera ? 1.0 : pScale);
    final showPose = selected || n.rx != 0 || n.ry != 0 || n.rz != 0;

    canvas.save();
    canvas.translate(outX * scaleX, outY * scaleY);
    canvas.rotate(n.rz * math.pi / 180.0);
    if (!isCamera) {
      // Yaw / pitch read as foreshorten on the flat stage (min so it never vanishes).
      final sq = SceneNode.foreshorten(n.rx, n.ry);
      canvas.scale(sq.$1, sq.$2);
    }
    final rect = Rect.fromCenter(
      center: Offset.zero,
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

    final glyph = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (isCamera) {
      canvas.drawCircle(Offset.zero, 6, glyph);
      if (showPose) _paintLocalAxes(canvas, 16);
      canvas.restore();
      // Frustum stays in stage space; roll it around the lens.
      canvas.save();
      canvas.translate(outX * scaleX, outY * scaleY);
      canvas.rotate(n.rz * math.pi / 180.0);
      canvas.translate(-outX * scaleX, -outY * scaleY);
      _paintCameraFrustum(canvas, n, scaleX, scaleY, selected);
      canvas.restore();
      return;
    }

    final meshId = SceneMeshes.normalize(n.mesh);
    if (meshId.isNotEmpty) {
      // Mesh silhouette in local node space (shared pose already applied).
      _paintMeshSilhouette(
        canvas,
        meshId,
        drawW * scaleX,
        drawH * scaleY,
        fill,
        selected,
      );
    } else {
      final g = 10.0 * pScale;
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: g, height: g),
        glyph,
      );
    }
    if (showPose) {
      final axis = math.max(12.0, math.min(rect.width, rect.height) * 0.35);
      _paintLocalAxes(canvas, axis);
    }
    canvas.restore();
  }

  /// Studio-side mesh hint (not GPU meshes). Drawn inside the node pose so
  /// editor and play share the same transform path (rx/ry/rz + depth scale).
  void _paintMeshSilhouette(
    Canvas canvas,
    String meshId,
    double bw,
    double bh,
    Color fill,
    bool selected,
  ) {
    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: selected ? 0.95 : 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 1.8 : 1.3
      ..strokeJoin = StrokeJoin.round;
    final fillP = Paint()..color = fill.withValues(alpha: selected ? 0.55 : 0.4);
    final hx = bw * 0.42;
    final hy = bh * 0.42;
    switch (meshId) {
      case SceneMeshes.crate:
      case SceneMeshes.metalcase:
        // Box: front face + top/side perspective lines (isometric-ish).
        final front = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: hx * 1.6, height: hy * 1.6),
          const Radius.circular(3),
        );
        canvas.drawRRect(front, fillP);
        canvas.drawRRect(front, stroke);
        final depth = math.min(hx, hy) * 0.35;
        final path = Path()
          ..moveTo(-hx * 0.8, -hy * 0.8)
          ..lineTo(-hx * 0.8 + depth, -hy * 0.8 - depth)
          ..lineTo(hx * 0.8 + depth, -hy * 0.8 - depth)
          ..lineTo(hx * 0.8, -hy * 0.8);
        canvas.drawPath(path, stroke);
        canvas.drawLine(
          Offset(hx * 0.8, -hy * 0.8),
          Offset(hx * 0.8 + depth, -hy * 0.8 - depth),
          stroke,
        );
        if (meshId == SceneMeshes.metalcase) {
          // Horizontal ribs
          canvas.drawLine(
            Offset(-hx * 0.65, -hy * 0.15),
            Offset(hx * 0.65, -hy * 0.15),
            stroke,
          );
          canvas.drawLine(
            Offset(-hx * 0.65, hy * 0.15),
            Offset(hx * 0.65, hy * 0.15),
            stroke,
          );
        } else {
          // Crate cross
          canvas.drawLine(
            Offset(-hx * 0.55, -hy * 0.55),
            Offset(hx * 0.55, hy * 0.55),
            stroke,
          );
          canvas.drawLine(
            Offset(hx * 0.55, -hy * 0.55),
            Offset(-hx * 0.55, hy * 0.55),
            stroke,
          );
        }
      case SceneMeshes.chest:
        final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(-hx * 0.85, -hy * 0.2, hx * 1.7, hy * 1.0),
          const Radius.circular(4),
        );
        canvas.drawRRect(body, fillP);
        canvas.drawRRect(body, stroke);
        // Lid arc
        final lid = Path()
          ..moveTo(-hx * 0.85, -hy * 0.2)
          ..quadraticBezierTo(0, -hy * 0.95, hx * 0.85, -hy * 0.2);
        canvas.drawPath(lid, stroke);
        canvas.drawCircle(Offset(0, hy * 0.15), 3, stroke);
      case SceneMeshes.sword:
        // Blade up + crossguard + pommel
        final blade = Path()
          ..moveTo(0, -hy * 0.95)
          ..lineTo(hx * 0.18, -hy * 0.15)
          ..lineTo(hx * 0.08, -hy * 0.15)
          ..lineTo(hx * 0.08, hy * 0.35)
          ..lineTo(-hx * 0.08, hy * 0.35)
          ..lineTo(-hx * 0.08, -hy * 0.15)
          ..lineTo(-hx * 0.18, -hy * 0.15)
          ..close();
        canvas.drawPath(blade, fillP);
        canvas.drawPath(blade, stroke);
        canvas.drawLine(
          Offset(-hx * 0.4, -hy * 0.12),
          Offset(hx * 0.4, -hy * 0.12),
          stroke,
        );
        canvas.drawCircle(Offset(0, hy * 0.48), 4, stroke);
      default:
        canvas.drawRect(
          Rect.fromCenter(center: Offset.zero, width: 10, height: 10),
          stroke,
        );
    }
  }

  /// Local +X (red) / +Y (green, stage-down). Call inside the node transform.
  void _paintLocalAxes(Canvas canvas, double len) {
    final xPaint = Paint()
      ..color = const Color(0xFFFF5252)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final yPaint = Paint()
      ..color = const Color(0xFF69F0AE)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(len, 0), xPaint);
    canvas.drawLine(Offset.zero, Offset(0, len), yPaint);
  }

  void _paintPoly(
    Canvas canvas,
    SceneNode n,
    Offset off,
    double scaleX,
    double scaleY,
    Color fill,
    Color stroke,
    bool selected, {
    required double pivotX,
    required double pivotY,
    required double midX,
    required double midY,
    required double depthScale,
  }) {
    final pts = n.points!;
    final sq = SceneNode.foreshorten(n.rx, n.ry);
    // Same order as rects: roll, then foreshorten, around the bounds center.
    // [pivot] is the projected center in play; in edit it is [mid].
    canvas.save();
    canvas.translate(pivotX * scaleX, pivotY * scaleY);
    canvas.rotate(n.rz * math.pi / 180.0);
    canvas.scale(sq.$1 * depthScale, sq.$2 * depthScale);
    final path = Path();
    final local = <Offset>[];
    for (var i = 0; i < pts.length; i++) {
      final lx = (pts[i].x + off.dx - midX) * scaleX;
      final ly = (pts[i].y + off.dy - midY) * scaleY;
      local.add(Offset(lx, ly));
      if (i == 0) {
        path.moveTo(lx, ly);
      } else {
        path.lineTo(lx, ly);
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
    if (selected || n.rx != 0 || n.ry != 0 || n.rz != 0) {
      _paintLocalAxes(canvas, 18);
    }
    // Vertex dots only in edit (play hides selection chrome upstream).
    if (selected && playTime <= 0) {
      for (var i = 0; i < local.length; i++) {
        final active = editPointIndex == i;
        canvas.drawCircle(
          local[i],
          active ? 7 : 5,
          Paint()..color = active ? const Color(0xFF69F0AE) : Colors.white,
        );
      }
    }
    canvas.restore();
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
        old.projectMode != projectMode ||
        old.playState != playState) {
      return true;
    }
    // ~120 Hz threshold: skip repaint if time delta is tiny (duplicate ticks).
    return (old.playTime - playTime).abs() > 0.008;
  }
}
