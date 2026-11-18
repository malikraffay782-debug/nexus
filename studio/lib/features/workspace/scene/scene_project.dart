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
/// Soft path stays the low-end default. NDC path is the Unity-class space
/// (world → camera → clip → NDC → stage) without requiring a GPU yet.
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

  /// Camera-space → NDC (OpenGL-style x/y in [-1,1]; z in [-1,1] mid-depth map).
  ///
  /// Stage Y is down; converted to Y-up before projection so [ndcToStage]
  /// flip is consistent. Returns null if outside near/far or w<=0.
  /// Lateral (|nx|/|ny|) is tested separately via [inNdcLateral].
  static (double nx, double ny, double nz)? toNdc(
    SceneCamFrame cam,
    double x,
    double y,
    double z,
  ) {
    final depth = cam.depthOf(z);
    if (depth < cam.near || depth > cam.far) return null;

    // Camera space: origin at eye, x right, y up, z forward.
    final xc = x - cam.cx;
    final yc = cam.cy - y; // stage Y-down → camera Y-up
    final zc = depth;

    final f = 1.0 / math.tan(cam.fovDeg * math.pi / 360.0);
    final a = cam.aspect <= 0 ? 1.0 : cam.aspect;
    // Perspective: clip then divide by zc.
    final xClip = f * xc / a;
    final yClip = f * yc;
    final w = zc;
    if (w <= 1e-9) return null;

    final nx = xClip / w;
    final ny = yClip / w;
    // Map near..far → -1..+1 (guard degenerate far==near).
    final span = cam.far - cam.near;
    final nz = span > 1e-9 ? ((zc - cam.near) / span) * 2.0 - 1.0 : 0.0;
    return (nx, ny, nz);
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
    double z,
  ) {
    final ndc = toNdc(cam, x, y, z);
    if (ndc == null) return false;
    return inNdcLateral(ndc.$1, ndc.$2);
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
  /// - [SceneProjectMode.soft]: depth slab only (near/far).
  /// - [SceneProjectMode.ndc]: depth + lateral FOV cone (|nx|,|ny| ≤ 1).
  static SceneProjected project(
    SceneCamFrame cam,
    double x,
    double y,
    double z, {
    SceneProjectMode mode = SceneProjectMode.soft,
  }) {
    if (mode == SceneProjectMode.soft) {
      return projectSoft(cam, x, y, z);
    }
    final ndc = toNdc(cam, x, y, z);
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
