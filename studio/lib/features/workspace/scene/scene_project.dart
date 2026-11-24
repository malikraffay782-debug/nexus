import 'dart:math' as math;

import 'scene_model.dart';

/// Projection path for play preview / future run bridge.
///
/// [soft] — cheap depth scale (default, low-end friendly; matches scene_draw.py).
/// [ndc]  — perspective → NDC → stage pixels (Unity-style space; opt-in).
///
/// ## Units
/// - **Stage XY**: pixel-like coordinates on the scene document
///   (`SceneDoc.width` × `height`, origin top-left, Y down).
/// - **Depth Z**: same numeric units as [SceneCamFrame.near] / [far]
///   (not forced to pixels). `depth = worldZ - cam.cz` with look **+Z**.
/// - Default gameplay: sprites at z≈0, camera at **negative z** so depth > near.
enum SceneProjectMode { soft, ndc }

/// Resolved camera + stage constants for one frame (no node refs held).
///
/// Convention: eye at (cx, cy, cz), default look **+Z**, depth = z - cz.
/// Optional [rx]/[ry]/[rz] (degrees) orient the NDC view matrix only;
/// soft path stays axis-aligned for low-end cost.
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
    this.rx = 0,
    this.ry = 0,
    this.rz = 0,
  });

  final double cx;
  final double cy;
  final double cz;
  final double near;
  final double far;
  final double fovDeg;
  final double stageW;
  final double stageH;
  /// Camera orientation degrees (same fields as [SceneNode]).
  final double rx;
  final double ry;
  final double rz;

  /// Resolve play/edit camera from [nodes].
  ///
  /// Prefer [preferredId] when it names a camera node (selected camera drives
  /// the play view). Otherwise first camera in list order. Null if none.
  static SceneCamFrame? fromNodes(
    List<SceneNode> nodes, {
    required double stageW,
    required double stageH,
    String? preferredId,
  }) {
    SceneNode? pick;
    if (preferredId != null && preferredId.isNotEmpty) {
      for (final n in nodes) {
        if (n.id == preferredId && n.isCamera) {
          pick = n;
          break;
        }
      }
    }
    if (pick == null) {
      for (final n in nodes) {
        if (n.isCamera) {
          pick = n;
          break;
        }
      }
    }
    if (pick == null) return null;

    final near = pick.near > 0 ? pick.near : SceneNode.defaultNear;
    final far = pick.far > near ? pick.far : SceneNode.defaultFar;
    return SceneCamFrame(
      cx: pick.x + pick.w * 0.5,
      cy: pick.y + pick.h * 0.5,
      cz: pick.z,
      near: near,
      far: far,
      fovDeg: pick.fov.clamp(1.0, 179.0),
      stageW: stageW,
      stageH: stageH,
      rx: pick.rx,
      ry: pick.ry,
      rz: pick.rz,
    );
  }

  /// Same lens / depth / pose, new eye XY (play follow — does not mutate nodes).
  SceneCamFrame withEyeXy(double x, double y) => SceneCamFrame(
        cx: x,
        cy: y,
        cz: cz,
        near: near,
        far: far,
        fovDeg: fovDeg,
        stageW: stageW,
        stageH: stageH,
        rx: rx,
        ry: ry,
        rz: rz,
      );

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

  /// View matrix: stage (x, y_down, z) → camera (x, y_up, depth).
  ///
  /// Default look +Z. When [rx]/[ry]/[rz] are set, applies inverse camera
  /// rotation after the eye translate (NDC path only).
  SceneMat4 viewMatrix() =>
      SceneMat4.viewLookPlusZ(cx, cy, cz, rx: rx, ry: ry, rz: rz);

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

  /// Stage → camera: translate −eye, flip Y (stage down → camera up), then
  /// optional inverse camera Euler (degrees: [rx] pitch, [ry] yaw, [rz] roll).
  ///
  /// Camera world pose is treated as R_cam = Ry(ry)·Rx(rx)·Rz(rz). View uses
  /// R_cam⁻¹ = Rz(−rz)·Rx(−rx)·Ry(−ry) after the fixed look-+Z frame.
  static SceneMat4 viewLookPlusZ(
    double eyeX,
    double eyeY,
    double eyeZ, {
    double rx = 0,
    double ry = 0,
    double rz = 0,
  }) {
    final base = SceneMat4(<double>[
      1, 0, 0, 0,
      0, -1, 0, 0,
      0, 0, 1, 0,
      -eyeX, eyeY, -eyeZ, 1,
    ]);
    if (rx == 0 && ry == 0 && rz == 0) return base;
    // inv = Rz(-rz) · Rx(-rx) · Ry(-ry)
    final inv = rotationZ(-rz).mul(rotationX(-rx)).mul(rotationY(-ry));
    return inv.mul(base);
  }

  static SceneMat4 rotationX(double deg) {
    final a = deg * math.pi / 180.0;
    final c = math.cos(a);
    final s = math.sin(a);
    return SceneMat4(<double>[
      1, 0, 0, 0,
      0, c, s, 0,
      0, -s, c, 0,
      0, 0, 0, 1,
    ]);
  }

  static SceneMat4 rotationY(double deg) {
    final a = deg * math.pi / 180.0;
    final c = math.cos(a);
    final s = math.sin(a);
    return SceneMat4(<double>[
      c, 0, -s, 0,
      0, 1, 0, 0,
      s, 0, c, 0,
      0, 0, 0, 1,
    ]);
  }

  static SceneMat4 rotationZ(double deg) {
    final a = deg * math.pi / 180.0;
    final c = math.cos(a);
    final s = math.sin(a);
    return SceneMat4(<double>[
      c, s, 0, 0,
      -s, c, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
    ]);
  }

  /// Symmetric perspective for **look +Z** (camera-space depth = +z).
  ///
  /// Classic OpenGL perspective assumes look −Z (clip w = −z_cam). Our view
  /// maps world depth to **+z_cam**, so w must be **+depth**. The z-row maps
  /// near→NDC −1 and far→NDC +1 after the perspective divide.
  ///
  /// [fovDeg] vertical; [aspect] = width/height.
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
    // nz = a + b/depth with w = +depth; near→−1, far→+1.
    final a = (safeFar + safeNear) / (safeFar - safeNear);
    final b = (-2.0 * safeFar * safeNear) / (safeFar - safeNear);
    return SceneMat4(<double>[
      f / safeAspect, 0, 0, 0,
      0, f, 0, 0,
      0, 0, a, 1, // +1 ⇒ clip w = +z_cam (look +Z)
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
    final ref = cam.softRef > 1e-9 ? cam.softRef : 1.0;
    return ref / (ref + d * cam.softFovK);
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

  /// Axis-aligned box vs camera frustum.
  ///
  /// [zDepth] 0 → flat plane at [z] (4 corners).
  /// [zDepth] > 0 → thickness around [z]: z±zDepth/2 (8 corners).
  /// Soft: z-extent overlaps soft depth range. NDC: any corner in frustum.
  static bool aabbVisible(
    SceneCamFrame cam,
    double x,
    double y,
    double w,
    double h,
    double z, {
    double zDepth = 0,
    SceneProjectMode mode = SceneProjectMode.soft,
    SceneMat4? viewProjection,
  }) {
    // Non-finite / negative thickness → treat as flat (avoids inverted z0/z1).
    final zd = (zDepth.isFinite && zDepth > 0) ? zDepth : 0.0;
    final half = zd * 0.5;
    final z0 = z - half;
    final z1 = z + half;
    final d0 = cam.depthOf(z0);
    final d1 = cam.depthOf(z1);
    final dMin = math.min(d0, d1);
    final dMax = math.max(d0, d1);

    if (mode == SceneProjectMode.soft) {
      return dMax >= 0 && dMin <= cam.far;
    }
    if (dMax < cam.near || dMin > cam.far) return false;

    final vp = viewProjection ?? cam.viewProjectionMatrix();
    final x1 = x + w;
    final y1 = y + h;
    bool corner(double px, double py, double pz) =>
        inNdcFrustum(cam, px, py, pz, viewProjection: vp);
    if (corner(x, y, z0)) return true;
    if (corner(x1, y, z0)) return true;
    if (corner(x, y1, z0)) return true;
    if (corner(x1, y1, z0)) return true;
    if (half > 0) {
      if (corner(x, y, z1)) return true;
      if (corner(x1, y, z1)) return true;
      if (corner(x, y1, z1)) return true;
      if (corner(x1, y1, z1)) return true;
    }
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

  /// Perspective size scale for NDC path: ~1 at [refDepth], falls as 1/depth.
  ///
  /// Uses the same depth axis as the projection matrix (not [depthScale] soft).
  static double perspectiveScale(SceneCamFrame cam, double depth) {
    final d = depth < cam.near ? cam.near : depth;
    final ref = cam.softRef > 1e-9 ? cam.softRef : 100.0;
    final s = ref / d;
    if (!s.isFinite) return 1.0;
    return s.clamp(0.05, 8.0);
  }

  /// Dispatch by [mode]. Default soft for low-end frames.
  ///
  /// - [SceneProjectMode.soft]: soft depth scale (no matrices).
  /// - [SceneProjectMode.ndc]: view×projection → NDC + lateral unit square;
  ///   size scale from [perspectiveScale] (1/depth), not soft.
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
    final depth = cam.depthOf(z);
    final s = perspectiveScale(cam, depth);
    return SceneProjected(x: sx, y: sy, scale: s, visible: true);
  }
}
