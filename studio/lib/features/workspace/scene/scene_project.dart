import 'dart:math' as math;

import 'scene_model.dart';

/// Projection path for play preview / future run bridge.
///
/// [soft] — cheap depth scale (default, low-end friendly; matches scene_draw.py).
/// [ndc]  — perspective → NDC → stage pixels (Unity-style space; opt-in).
enum SceneProjectMode { soft, ndc }

/// Resolved camera + stage constants for one frame (no node refs held).
///
/// Convention: eye at (cx, cy, cz), look **+Z**, depth = z - cz.
class SceneCamFrame {
  const SceneCamFrame({
    required this.cx,
    required this.cy,
    required this.cz,
    required this.near,
    required this.far,
    required this.fovDeg,
    required this.stageW,
    required this.stageH,
  });

  final double cx;
  final double cy;
  final double cz;
  final double near;
  final double far;
  final double fovDeg;
  final double stageW;
  final double stageH;

  /// First camera in [nodes], or null.
  static SceneCamFrame? fromNodes(
    List<SceneNode> nodes, {
    required double stageW,
    required double stageH,
  }) {
    for (final n in nodes) {
      if (!n.isCamera) continue;
      final near = n.near > 0 ? n.near : SceneNode.defaultNear;
      final far = n.far > near ? n.far : SceneNode.defaultFar;
      return SceneCamFrame(
        cx: n.x + n.w * 0.5,
        cy: n.y + n.h * 0.5,
        cz: n.z,
        near: near,
        far: far,
        fovDeg: n.fov.clamp(1.0, 179.0),
        stageW: stageW,
        stageH: stageH,
      );
    }
    return null;
  }

  double get aspect => stageH > 0 ? stageW / stageH : 1.0;

  /// Soft-path FOV weight (scene_draw.py compatible).
  double get softFovK => (fovDeg / 60.0).clamp(0.35, 2.5);

  /// Soft-path reference length from stage size.
  double get softRef => math.max(stageW, stageH) * 0.35;

  /// Camera-space depth (look +Z).
  double depthOf(double z) => z - cz;

  /// Soft visibility: in front of / on the eye plane through far.
  /// Includes [0, near) so default z=0 sprites still draw when cam.z=0
  /// (near is used for scale, not hard reject, on the soft path).
  bool inSoftDepth(double depth) => depth >= 0 && depth <= far;

  /// Strict near/far slab (NDC / true frustum).
  bool inDepthSlab(double depth) => depth >= near && depth <= far;

  /// View matrix: stage (x, y_down, z) → camera (x, y_up, depth), look +Z.
  SceneMat4 viewMatrix() => SceneMat4.viewLookPlusZ(cx, cy, cz);

  /// Perspective projection (OpenGL-style clip, z → NDC −1…+1).
  SceneMat4 projectionMatrix() =>
      SceneMat4.perspective(fovDeg, aspect, near, far);

  /// Cached VP = P × V for this frame (build once per paint when needed).
  SceneMat4 viewProjectionMatrix() => projectionMatrix().mul(viewMatrix());
}

/// Column-major 4×4 matrix — pure Dart, no GPU package.
///
/// Layout matches OpenGL: index = col * 4 + row.
class SceneMat4 {
  SceneMat4(this.m) : assert(m.length == 16);

  /// 16 elements, column-major.
  final List<double> m;

  static SceneMat4 identity() => SceneMat4(<double>[
        1, 0, 0, 0, // col0
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
      ]);

  /// Stage → camera: translate −eye, then flip Y (stage down → camera up).
  static SceneMat4 viewLookPlusZ(double eyeX, double eyeY, double eyeZ) {
    return SceneMat4(<double>[
      1, 0, 0, 0,
      0, -1, 0, 0,
      0, 0, 1, 0,
      -eyeX, eyeY, -eyeZ, 1,
    ]);
  }

  /// Symmetric perspective; [fovDeg] vertical; [aspect] = width/height.
  static SceneMat4 perspective(
    double fovDeg,
    double aspect,
    double near,
    double far,
  ) {
    final safeAspect = aspect <= 1e-9 ? 1.0 : aspect;
    final safeNear = near <= 1e-6 ? 1e-6 : near;
    final safeFar = far > safeNear + 1e-6 ? far : safeNear + 1e-6;
    final f = 1.0 / math.tan(fovDeg * math.pi / 360.0);
    final a = (safeFar + safeNear) / (safeNear - safeFar);
    final b = (2.0 * safeFar * safeNear) / (safeNear - safeFar);
    return SceneMat4(<double>[
      f / safeAspect, 0, 0, 0,
      0, f, 0, 0,
      0, 0, a, -1,
      0, 0, b, 0,
    ]);
  }

  /// this × other (column-major).
  SceneMat4 mul(SceneMat4 other) {
    final a = m;
    final b = other.m;
    final o = List<double>.filled(16, 0);
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += a[k * 4 + row] * b[col * 4 + k];
        }
        o[col * 4 + row] = s;
      }
    }
    return SceneMat4(o);
  }

  /// Transform point (x,y,z,1) → (x',y',z',w').
  (double x, double y, double z, double w) transformPoint(
    double x,
    double y,
    double z,
  ) {
    final e = m;
    final xw = e[0] * x + e[4] * y + e[8] * z + e[12];
    final yw = e[1] * x + e[5] * y + e[9] * z + e[13];
    final zw = e[2] * x + e[6] * y + e[10] * z + e[14];
    final ww = e[3] * x + e[7] * y + e[11] * z + e[15];
    return (xw, yw, zw, ww);
  }
}

/// One projected sample in stage (pixel-like) space.
class SceneProjected {
  const SceneProjected({
    required this.x,
    required this.y,
    required this.scale,
    required this.visible,
  });

  final double x;
  final double y;
  /// Uniform size scale (~1 near camera; smaller with depth).
  final double scale;
  final bool visible;

  static const identity = SceneProjected(x: 0, y: 0, scale: 1, visible: true);
}

/// Pure projection helpers — no Flutter/GPU.
///
/// Soft path stays the low-end default. NDC path uses view×projection
/// matrices (Unity-style) then perspective divide — still CPU-only.
class SceneProject {
  SceneProject._();

  /// Soft depth scale in (0, 1], same idea as scene_draw.py.
  static double depthScale(SceneCamFrame cam, double depth) {
    final d = math.max(depth, cam.near);
    return cam.softRef / (cam.softRef + d * cam.softFovK);
  }

  /// Soft project: pull toward camera center in stage pixels.
  static SceneProjected projectSoft(
    SceneCamFrame cam,
    double x,
    double y,
    double z,
  ) {
    final depth = cam.depthOf(z);
    if (!cam.inSoftDepth(depth)) {
      return SceneProjected(x: x, y: y, scale: 1, visible: false);
    }
    final s = depthScale(cam, depth);
    return SceneProjected(
      x: cam.cx + (x - cam.cx) * s,
      y: cam.cy + (y - cam.cy) * s,
      scale: s,
      visible: true,
    );
  }

  /// World/stage → NDC via view×projection (perspective divide).
  ///
  /// Returns null if behind the projection (w<=0) or outside near/far depth
  /// slab. Lateral (|nx|/|ny|) tested separately via [inNdcLateral].
  static (double nx, double ny, double nz)? toNdc(
    SceneCamFrame cam,
    double x,
    double y,
    double z, {
    SceneMat4? viewProjection,
  }) {
    final depth = cam.depthOf(z);
    if (depth < cam.near || depth > cam.far) return null;

    final vp = viewProjection ?? cam.viewProjectionMatrix();
    final (cx, cy, cz, cw) = vp.transformPoint(x, y, z);
    if (cw <= 1e-9) return null;
    final invW = 1.0 / cw;
    return (cx * invW, cy * invW, cz * invW);
  }

  /// True if NDC x/y lie inside the unit square (FOV left/right/top/bottom).
  /// Soft path does **not** use this — depth slab only for low-end cost.
  static bool inNdcLateral(double nx, double ny) =>
      nx >= -1.0 && nx <= 1.0 && ny >= -1.0 && ny <= 1.0;

  /// Full NDC frustum test: depth (via [toNdc] non-null) + lateral unit square.
  static bool inNdcFrustum(
    SceneCamFrame cam,
    double x,
    double y,
    double z, {
    SceneMat4? viewProjection,
  }) {
    final ndc = toNdc(cam, x, y, z, viewProjection: viewProjection);
    if (ndc == null) return false;
    return inNdcLateral(ndc.$1, ndc.$2);
  }

  /// Axis-aligned stage rect at constant [z] vs camera frustum.
  ///
  /// Soft: depth of the plane only (no lateral).
  /// NDC: any of the 4 corners inside depth+lateral → visible (Unity-style
  /// bounds test lite — flat Z slab, not a full 3D AABB).
  static bool aabbVisible(
    SceneCamFrame cam,
    double x,
    double y,
    double w,
    double h,
    double z, {
    SceneProjectMode mode = SceneProjectMode.soft,
    SceneMat4? viewProjection,
  }) {
    final depth = cam.depthOf(z);
    if (mode == SceneProjectMode.soft) {
      return cam.inSoftDepth(depth);
    }
    if (!cam.inDepthSlab(depth)) return false;
    final vp = viewProjection ?? cam.viewProjectionMatrix();
    final x1 = x + w;
    final y1 = y + h;
    // 4 corners — early out on first hit.
    if (inNdcFrustum(cam, x, y, z, viewProjection: vp)) return true;
    if (inNdcFrustum(cam, x1, y, z, viewProjection: vp)) return true;
    if (inNdcFrustum(cam, x, y1, z, viewProjection: vp)) return true;
    if (inNdcFrustum(cam, x1, y1, z, viewProjection: vp)) return true;
    return false;
  }

  /// NDC → stage pixels (top-left origin, Y-down like Flutter).
  static (double x, double y) ndcToStage(
    SceneCamFrame cam,
    double nx,
    double ny,
  ) {
    final x = (nx + 1.0) * 0.5 * cam.stageW;
    // NDC y+ is up; stage y+ is down → flip.
    final y = (1.0 - ny) * 0.5 * cam.stageH;
    return (x, y);
  }

  /// Dispatch by [mode]. Default soft for low-end frames.
  ///
  /// - [SceneProjectMode.soft]: soft depth scale (no matrices).
  /// - [SceneProjectMode.ndc]: view×projection → NDC + lateral unit square.
  static SceneProjected project(
    SceneCamFrame cam,
    double x,
    double y,
    double z, {
    SceneProjectMode mode = SceneProjectMode.soft,
    SceneMat4? viewProjection,
  }) {
    if (mode == SceneProjectMode.soft) {
      return projectSoft(cam, x, y, z);
    }
    final vp = viewProjection ?? cam.viewProjectionMatrix();
    final ndc = toNdc(cam, x, y, z, viewProjection: vp);
    if (ndc == null) {
      return SceneProjected(x: x, y: y, scale: 1, visible: false);
    }
    final (nx, ny, _) = ndc;
    // Lateral frustum cull (Unity-style clip volume on x/y).
    if (!inNdcLateral(nx, ny)) {
      return SceneProjected(x: x, y: y, scale: 1, visible: false);
    }
    final (sx, sy) = ndcToStage(cam, nx, ny);
    // Size scale from depth (same soft weight) so rects still shrink.
    final depth = cam.depthOf(z);
    final s = depthScale(cam, depth);
    return SceneProjected(x: sx, y: sy, scale: s, visible: true);
  }
}
