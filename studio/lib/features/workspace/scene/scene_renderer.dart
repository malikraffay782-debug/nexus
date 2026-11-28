import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'scene_mesh_wire.dart';
import 'scene_model.dart';
import 'scene_play_state.dart';
import 'scene_project.dart';
import 'scene_sprite_cache.dart';

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
    this.spriteCache,
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
  /// Optional project sprite decode cache (2 GB capped).
  final SceneSpriteCache? spriteCache;

  // Reused paints — avoid per-frame Paint() on low-end (B11).
  static final Paint _bgPaint = Paint()..color = const Color(0xFF1A1A22);
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
        final ps = playState;
        if (center != null && ps != null) {
          // Follow Player XY + Z; keep authored cam↔player depth gap.
          final eyeZ = ps.playerZ + (cam.cz - ps.playerAuthoredZ);
          cam = cam.withEyeXyz(center.dx, center.dy, eyeZ);
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

    // Depth order: non-cameras far→near; cameras last. Stable on ties.
    // Play uses worldZ (Player Z) + camera depthOf when a cam is active so
    // Q/E depth moves reorder draw (painter's algorithm, low-end safe).
    final ordered = List<SceneNode>.of(nodes);
    if (count > 1) {
      ordered.sort((a, b) {
        final ac = a.isCamera ? 1 : 0;
        final bc = b.isCamera ? 1 : 0;
        if (ac != bc) return ac - bc;
        final za = playState?.worldZ(a) ?? a.z;
        final zb = playState?.worldZ(b) ?? b.z;
        if (cam != null) {
          // Larger depth = farther; draw far first so near paints on top.
          final da = cam.depthOf(za);
          final db = cam.depthOf(zb);
          final cd = db.compareTo(da);
          if (cd != 0) return cd;
        } else {
          final cz = za.compareTo(zb);
          if (cz != 0) return cz;
        }
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
    // Player can move in Z during play; others keep authored z.
    final wz = playState?.worldZ(n) ?? n.z;
    var pScale = 1.0;
    var outX = midX;
    var outY = midY;
    if (!isCamera && cam != null) {
      // Rotated nodes: inflate AABB to diagonal so cull is not too aggressive (B26).
      var cullX = boundX;
      var cullY = boundY;
      var cullW = boundW;
      var cullH = boundH;
      if (n.rx != 0 || n.ry != 0 || n.rz != 0) {
        final diag = math.sqrt(boundW * boundW + boundH * boundH);
        final cx = boundX + boundW * 0.5;
        final cy = boundY + boundH * 0.5;
        cullX = cx - diag * 0.5;
        cullY = cy - diag * 0.5;
        cullW = diag;
        cullH = diag;
      }
      final visible = SceneProject.aabbVisible(
        cam,
        cullX,
        cullY,
        cullW,
        cullH,
        wz,
        zDepth: n.zDepth,
        mode: projectMode,
        viewProjection: _viewProjection,
      );
      if (!visible) return;
      final pr = _project(midX, midY, wz);
      // Center may be outside while a corner is inside — still draw at
      // projected center if possible; else keep stage center.
      if (pr.visible) {
        pScale = pr.scale;
        outX = pr.x;
        outY = pr.y;
      } else {
        pScale = SceneProject.depthScale(cam, cam.depthOf(wz));
      }
    }

    final fill = Color(n.color).withValues(alpha: selected ? 0.95 : 0.85);
    final stroke = selected ? Colors.white : fill;

    // Play/NDC: project mesh wires in stage space (box = 8-corner volume;
    // sword/chest = planar unit edges on node Z).
    final meshIdCam = SceneMeshes.normalize(n.mesh);
    if (!isCamera && cam != null && !n.hasPoints && meshIdCam.isNotEmpty) {
      if (SceneMeshWire.isBoxMesh(meshIdCam)) {
        _paintProjectedBox(
          canvas,
          midX: midX,
          midY: midY,
          z: wz,
          w: boundW,
          h: boundH,
          zDepth: n.zDepth,
          rz: n.rz,
          scaleX: scaleX,
          scaleY: scaleY,
          fill: fill,
          selected: selected,
          brace: meshIdCam == SceneMeshes.metalcase,
        );
      } else {
        _paintProjectedPlanarMesh(
          canvas,
          meshId: meshIdCam,
          midX: midX,
          midY: midY,
          z: wz,
          w: boundW,
          h: boundH,
          rz: n.rz,
          scaleX: scaleX,
          scaleY: scaleY,
          fill: fill,
          selected: selected,
        );
      }
      return;
    }

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
    final meshId = isCamera ? SceneMeshes.none : SceneMeshes.normalize(n.mesh);
    final hasMesh = meshId.isNotEmpty;

    if (isCamera || !hasMesh) {
      final rrect = RRect.fromRectAndRadius(
        rect,
        Radius.circular(isCamera ? 20 : 6),
      );
      // Prefer size-capped sprite under assets/; else solid color.
      final spr = isCamera ? null : spriteCache?.get(n.sprite);
      if (spr != null) {
        canvas.save();
        canvas.clipRRect(rrect);
        paintImage(
          canvas: canvas,
          rect: rect,
          image: spr,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
        );
        canvas.restore();
      } else {
        if (!isCamera && n.sprite.isNotEmpty) {
          spriteCache?.prefer(n.sprite);
        }
        canvas.drawRRect(rrect, Paint()..color = fill);
      }
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2.5 : 1.2,
      );
    }

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

    if (hasMesh) {
      // Optional sprite under the wire (texture + silhouette).
      final spr = spriteCache?.get(n.sprite);
      if (spr != null) {
        final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
        canvas.save();
        canvas.clipRRect(rrect);
        paintImage(
          canvas: canvas,
          rect: rect,
          image: spr,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
        );
        canvas.restore();
      } else if (n.sprite.isNotEmpty) {
        spriteCache?.prefer(n.sprite);
      }
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

  /// Planar mesh wire (sword/chest): unit edges on the node Z plane,
  /// each endpoint through [SceneProject.projectForWire].
  void _paintProjectedPlanarMesh(
    Canvas canvas, {
    required String meshId,
    required double midX,
    required double midY,
    required double z,
    required double w,
    required double h,
    double rz = 0,
    required double scaleX,
    required double scaleY,
    required Color fill,
    required bool selected,
  }) {
    final hw = w * 0.5;
    final hh = h * 0.5;
    if (hw < 1e-3 || hh < 1e-3) return;

    final cam = _cam;
    if (cam == null) return;

    final rad = rz * math.pi / 180.0;
    final cosR = math.cos(rad);
    final sinR = math.sin(rad);

    Offset? projectUnit(Offset u) {
      final lx = u.dx * hw;
      final ly = u.dy * hh;
      final rx = lx * cosR - ly * sinR;
      final ry = lx * sinR + ly * cosR;
      final pr = SceneProject.projectForWire(
        cam,
        midX + rx,
        midY + ry,
        z,
        mode: projectMode,
        viewProjection: _viewProjection,
      );
      if (!pr.visible) return null;
      return Offset(pr.x * scaleX, pr.y * scaleY);
    }

    final wire = Paint()
      ..color = Colors.white.withValues(alpha: selected ? 0.95 : 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 1.8 : 1.3
      ..strokeJoin = StrokeJoin.round;

    // Soft fill from projected unit fill path samples (polyline).
    final fillSrc = SceneMeshWire.fillPath(meshId);
    if (fillSrc != null) {
      final metrics = fillSrc.computeMetrics();
      final pts = <Offset>[];
      for (final m in metrics) {
        // Few samples — low-end safe, no dense tessellation.
        const steps = 8;
        for (var i = 0; i <= steps; i++) {
          final t = m.length * (i / steps);
          final tan = m.getTangentForOffset(t);
          if (tan == null) continue;
          final p = projectUnit(tan.position);
          if (p != null) pts.add(p);
        }
      }
      if (pts.length >= 3) {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (var i = 1; i < pts.length; i++) {
          path.lineTo(pts[i].dx, pts[i].dy);
        }
        path.close();
        canvas.drawPath(
          path,
          Paint()..color = fill.withValues(alpha: selected ? 0.4 : 0.28),
        );
      }
    }

    void drawEdges(List<MeshEdge> edges) {
      for (final e in edges) {
        final a = projectUnit(e.a);
        final b = projectUnit(e.b);
        if (a == null || b == null) continue;
        canvas.drawLine(a, b, wire);
      }
    }

    drawEdges(SceneMeshWire.edges(meshId));
    drawEdges(SceneMeshWire.extraEdges(meshId));
  }

  /// Projected AABB wire: 8 world corners → [SceneProject.projectForWire].
  /// Used for crate/metalcase when a camera is active (play or NDC preview).
  void _paintProjectedBox(
    Canvas canvas, {
    required double midX,
    required double midY,
    required double z,
    required double w,
    required double h,
    required double zDepth,
    double rz = 0,
    required double scaleX,
    required double scaleY,
    required Color fill,
    required bool selected,
    bool brace = false,
  }) {
    final hw = w * 0.5;
    final hh = h * 0.5;
    final depth = (zDepth.isFinite && zDepth > 1e-3)
        ? zDepth
        : math.min(w, h).clamp(8.0, 200.0) * 0.5;
    final hd = depth * 0.5;

    final rad = rz * math.pi / 180.0;
    final cosR = math.cos(rad);
    final sinR = math.sin(rad);

    final pts = List<Offset?>.filled(8, null);
    var any = false;
    for (var i = 0; i < 8; i++) {
      final lx = (i & 1) == 0 ? -hw : hw;
      final ly = (i & 2) == 0 ? -hh : hh;
      final px = midX + lx * cosR - ly * sinR;
      final py = midY + lx * sinR + ly * cosR;
      final pz = z + ((i & 4) == 0 ? -hd : hd);
      final pr = SceneProject.projectForWire(
        _cam!,
        px,
        py,
        pz,
        mode: projectMode,
        viewProjection: _viewProjection,
      );
      if (!pr.visible) continue;
      pts[i] = Offset(pr.x * scaleX, pr.y * scaleY);
      any = true;
    }
    if (!any) return;

    final wire = Paint()
      ..color = Colors.white.withValues(alpha: selected ? 0.95 : 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 1.8 : 1.3
      ..strokeJoin = StrokeJoin.round;

    for (final e in SceneMeshWire.boxEdgeIndices) {
      final a = pts[e.$1];
      final b = pts[e.$2];
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, wire);
    }

    if (brace) {
      final a = pts[0];
      final b = pts[3];
      final cpt = pts[1];
      final d = pts[2];
      if (a != null && b != null) canvas.drawLine(a, b, wire);
      if (cpt != null && d != null) canvas.drawLine(cpt, d, wire);
    }

    final f0 = pts[0];
    final f1 = pts[1];
    final f2 = pts[3];
    final f3 = pts[2];
    if (f0 != null && f1 != null && f2 != null && f3 != null) {
      final path = Path()
        ..moveTo(f0.dx, f0.dy)
        ..lineTo(f1.dx, f1.dy)
        ..lineTo(f2.dx, f2.dy)
        ..lineTo(f3.dx, f3.dy)
        ..close();
      canvas.drawPath(
        path,
        Paint()..color = fill.withValues(alpha: selected ? 0.4 : 0.28),
      );
    }
  }

  /// Studio-side mesh wire (not GPU meshes). Uses [SceneMeshWire] unit edges
  /// scaled into the node pose so editor and play share the same transform.
  void _paintMeshSilhouette(
    Canvas canvas,
    String meshId,
    double bw,
    double bh,
    Color fill,
    bool selected,
  ) {
    final halfW = bw * 0.5;
    final halfH = bh * 0.5;
    if (halfW < 1 || halfH < 1) return;

    final fillPath = SceneMeshWire.fillPath(meshId);
    if (fillPath != null) {
      canvas.save();
      canvas.scale(halfW, halfH);
      canvas.drawPath(
        fillPath,
        Paint()..color = fill.withValues(alpha: selected ? 0.5 : 0.35),
      );
      canvas.restore();
    }

    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: selected ? 0.95 : 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 1.8 : 1.3
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    void drawEdges(List<MeshEdge> edges) {
      for (final e in edges) {
        final a = SceneMeshWire.mapPoint(e.a, halfW, halfH);
        final b = SceneMeshWire.mapPoint(e.b, halfW, halfH);
        canvas.drawLine(a, b, stroke);
      }
    }

    drawEdges(SceneMeshWire.edges(meshId));
    drawEdges(SceneMeshWire.extraEdges(meshId));
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
        old.playState != playState ||
        old.spriteCache?.epoch != spriteCache?.epoch) {
      return true;
    }
    // ~120 Hz threshold: skip repaint if time delta is tiny (duplicate ticks).
    return (old.playTime - playTime).abs() > 0.008;
  }
}
