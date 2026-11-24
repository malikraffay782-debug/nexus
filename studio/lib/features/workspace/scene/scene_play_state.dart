import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'scene_model.dart';

/// Runtime play pose — never writes scene JSON / [SceneDoc].
///
/// Holds a copy of node XY (+ velocity for the Player). [update] integrates
/// steer with real [dt] (clamped). Releasing the stick leaves the Player
/// where it stopped (no snap-back to the authored pose).
class ScenePlayState {
  ScenePlayState._({
    required this.stageW,
    required this.stageH,
    required Map<String, Offset> positions,
    required Map<String, Offset> velocities,
    required this.playerId,
  })  : _positions = positions,
        _velocities = velocities;

  /// Snapshot from [doc] at play start.
  factory ScenePlayState.fromDoc(SceneDoc doc) {
    final positions = <String, Offset>{};
    final velocities = <String, Offset>{};
    String? playerId;
    for (final n in doc.nodes) {
      if (n.isCamera) continue;
      positions[n.id] = Offset(n.x, n.y);
      velocities[n.id] = Offset.zero;
      if (playerId == null && n.name.toLowerCase() == 'player') {
        playerId = n.id;
      }
    }
    return ScenePlayState._(
      stageW: doc.width.toDouble(),
      stageH: doc.height.toDouble(),
      positions: positions,
      velocities: velocities,
      playerId: playerId,
    );
  }

  final double stageW;
  final double stageH;
  final String? playerId;

  final Map<String, Offset> _positions;
  final Map<String, Offset> _velocities;

  /// Max simulation step (avoids huge jumps after a hitch). ~1/20 s.
  static const double maxDt = 1.0 / 20.0;

  /// Stage units per second at full stick.
  static const double moveSpeed = 220.0;

  /// Velocity decay when stick released (units/s² toward zero).
  static const double damping = 900.0;

  Offset positionOf(String id) => _positions[id] ?? Offset.zero;

  Offset velocityOf(String id) => _velocities[id] ?? Offset.zero;

  /// Authoring pose + runtime offset for drawing (Player moves; others stay).
  Offset runtimeOffset(SceneNode n) {
    if (n.isCamera) return Offset.zero;
    final p = _positions[n.id];
    if (p == null) return Offset.zero;
    return Offset(p.dx - n.x, p.dy - n.y);
  }

  /// Center of the Player sprite in stage space, or null.
  Offset? playerCenter(SceneDoc doc) {
    final id = playerId;
    if (id == null) return null;
    SceneNode? node;
    for (final n in doc.nodes) {
      if (n.id == id) {
        node = n;
        break;
      }
    }
    if (node == null) return null;
    final p = positionOf(id);
    return Offset(p.dx + node.w * 0.5, p.dy + node.h * 0.5);
  }

  /// Integrate one frame. [steer] is unit-ish (−1…1) in stage axes (y down).
  void update(double dt, Offset steer) {
    var step = dt;
    if (!step.isFinite || step <= 0) return;
    if (step > maxDt) step = maxDt;

    final id = playerId;
    if (id == null) return;

    var pos = _positions[id] ?? Offset.zero;
    var vel = _velocities[id] ?? Offset.zero;

    final sx = steer.dx.clamp(-1.0, 1.0);
    final sy = steer.dy.clamp(-1.0, 1.0);
    final mag = math.sqrt(sx * sx + sy * sy);

    if (mag > 0.05) {
      // Direct velocity toward stick (responsive on low-end, no accel lag).
      final inv = 1.0 / mag;
      vel = Offset(sx * inv * moveSpeed, sy * inv * moveSpeed);
    } else {
      // Release: damp velocity; do not snap position back to authored pose.
      final vMag = vel.distance;
      if (vMag < 1.0) {
        vel = Offset.zero;
      } else {
        final decel = damping * step;
        final scale = math.max(0.0, (vMag - decel) / vMag);
        vel = vel * scale;
      }
    }

    pos = Offset(pos.dx + vel.dx * step, pos.dy + vel.dy * step);

    // Clamp top-left of a default 64×64-ish footprint; keep on stage.
    const margin = 8.0;
    final maxX = math.max(margin, stageW - 64 - margin);
    final maxY = math.max(margin, stageH - 64 - margin);
    pos = Offset(
      pos.dx.clamp(margin, maxX),
      pos.dy.clamp(margin, maxY),
    );

    _positions[id] = pos;
    _velocities[id] = vel;
  }
}
