/// Lightweight studio mesh wireframes (no GPU, no asset load).
///
/// Unit space: roughly [-1, 1] in X/Y. Renderer scales by node draw size.
/// Box meshes use a fixed depth cue (back face offset) — not a full GPU mesh.


import 'package:flutter/material.dart';

import 'scene_model.dart';

/// One stroke in unit mesh space.
class MeshEdge {
  const MeshEdge(this.a, this.b);
  final Offset a;
  final Offset b;
}

/// Built-in wire topology for [SceneMeshes] ids.
class SceneMeshWire {
  SceneMeshWire._();

  /// Edges in unit space for [meshId], or empty if none/unknown.
  static List<MeshEdge> edges(String meshId) {
    switch (SceneMeshes.normalize(meshId)) {
      case SceneMeshes.crate:
      case SceneMeshes.metalcase:
        return _box;
      case SceneMeshes.chest:
        return _chest;
      case SceneMeshes.sword:
        return _sword;
      default:
        return const [];
    }
  }

  /// Optional closed fill path (unit space) for a soft body under the wire.
  static Path? fillPath(String meshId) {
    switch (SceneMeshes.normalize(meshId)) {
      case SceneMeshes.crate:
      case SceneMeshes.metalcase:
        return Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTRB(-0.8, -0.8, 0.8, 0.8),
              const Radius.circular(0.06),
            ),
          );
      case SceneMeshes.chest:
        return Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTRB(-0.85, -0.2, 0.85, 0.8),
              const Radius.circular(0.08),
            ),
          );
      case SceneMeshes.sword:
        final p = Path()
          ..moveTo(0, -0.95)
          ..lineTo(0.18, -0.15)
          ..lineTo(0.08, -0.15)
          ..lineTo(0.08, 0.35)
          ..lineTo(-0.08, 0.35)
          ..lineTo(-0.08, -0.15)
          ..lineTo(-0.18, -0.15)
          ..close();
        return p;
      default:
        return null;
    }
  }

  /// Isometric-ish unit box: front face + back face + connecting edges.
  static final List<MeshEdge> _box = _buildBox();

  static List<MeshEdge> _buildBox() {
    const d = 0.28; // back-face offset (depth cue)
    // Front face corners: FL, FR, BR, BL (Y up in unit mesh; renderer Y-down ok)
    const fl = Offset(-0.8, -0.8);
    const fr = Offset(0.8, -0.8);
    const br = Offset(0.8, 0.8);
    const bl = Offset(-0.8, 0.8);
    final fl2 = Offset(fl.dx + d, fl.dy - d);
    final fr2 = Offset(fr.dx + d, fr.dy - d);
    final br2 = Offset(br.dx + d, br.dy - d);
    final bl2 = Offset(bl.dx + d, bl.dy - d);
    return [
      // front
      MeshEdge(fl, fr),
      MeshEdge(fr, br),
      MeshEdge(br, bl),
      MeshEdge(bl, fl),
      // back
      MeshEdge(fl2, fr2),
      MeshEdge(fr2, br2),
      MeshEdge(br2, bl2),
      MeshEdge(bl2, fl2),
      // sides
      MeshEdge(fl, fl2),
      MeshEdge(fr, fr2),
      MeshEdge(br, br2),
      MeshEdge(bl, bl2),
    ];
  }

  static final List<MeshEdge> _chest = [
    // body outline
    const MeshEdge(Offset(-0.85, -0.2), Offset(0.85, -0.2)),
    const MeshEdge(Offset(0.85, -0.2), Offset(0.85, 0.8)),
    const MeshEdge(Offset(0.85, 0.8), Offset(-0.85, 0.8)),
    const MeshEdge(Offset(-0.85, 0.8), Offset(-0.85, -0.2)),
    // lid peak (polyline)
    const MeshEdge(Offset(-0.85, -0.2), Offset(0, -0.95)),
    const MeshEdge(Offset(0, -0.95), Offset(0.85, -0.2)),
    // latch mark
    const MeshEdge(Offset(-0.06, 0.12), Offset(0.06, 0.12)),
    const MeshEdge(Offset(0, 0.06), Offset(0, 0.22)),
  ];

  static final List<MeshEdge> _sword = [
    // blade outline
    const MeshEdge(Offset(0, -0.95), Offset(0.18, -0.15)),
    const MeshEdge(Offset(0.18, -0.15), Offset(0.08, -0.15)),
    const MeshEdge(Offset(0.08, -0.15), Offset(0.08, 0.35)),
    const MeshEdge(Offset(0.08, 0.35), Offset(-0.08, 0.35)),
    const MeshEdge(Offset(-0.08, 0.35), Offset(-0.08, -0.15)),
    const MeshEdge(Offset(-0.08, -0.15), Offset(-0.18, -0.15)),
    const MeshEdge(Offset(-0.18, -0.15), Offset(0, -0.95)),
    // crossguard
    const MeshEdge(Offset(-0.4, -0.12), Offset(0.4, -0.12)),
    // pommel (diamond)
    const MeshEdge(Offset(0, 0.4), Offset(0.1, 0.5)),
    const MeshEdge(Offset(0.1, 0.5), Offset(0, 0.6)),
    const MeshEdge(Offset(0, 0.6), Offset(-0.1, 0.5)),
    const MeshEdge(Offset(-0.1, 0.5), Offset(0, 0.4)),
  ];

  /// Scale unit edges into pixel offsets centered at origin.
  static Offset mapPoint(Offset u, double halfW, double halfH) =>
      Offset(u.dx * halfW, u.dy * halfH);

  /// Edge count helper for tests.
  static int edgeCount(String meshId) => edges(meshId).length;

  /// Metal case gets an extra X brace on the front face.
  static List<MeshEdge> extraEdges(String meshId) {
    if (SceneMeshes.normalize(meshId) != SceneMeshes.metalcase) {
      return const [];
    }
    return const [
      MeshEdge(Offset(-0.55, -0.55), Offset(0.55, 0.55)),
      MeshEdge(Offset(0.55, -0.55), Offset(-0.55, 0.55)),
    ];
  }

  /// Sanity: unit points should stay in a bounded range (low-end safe).
  static bool unitBoundsOk(String meshId) {
    for (final e in edges(meshId)) {
      for (final p in [e.a, e.b]) {
        if (!p.dx.isFinite || !p.dy.isFinite) return false;
        if (p.dx.abs() > 1.5 || p.dy.abs() > 1.5) return false;
      }
    }
    return true;
  }

  /// Prevent unused math import on some analyzer configs.
}
