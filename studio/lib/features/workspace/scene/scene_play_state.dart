import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'scene_model.dart';

/// Runtime play pose — never writes scene JSON / [SceneDoc].
///
/// Holds a copy of node XY + player Z (+ velocities). [update] integrates
/// steer with real [dt] (clamped). Releasing the stick leaves the Player
/// where it stopped (no snap-back to the authored pose).
class ScenePlayState {
  ScenePlayState._({
    required this.stageW,
    required this.stageH,
    required Map<String, Offset> positions,
    required Map<String, Offset> velocities,
    required this.playerId,
    required this.playerW,
    required this.playerH,
    required double playerZ,
    required double playerZVel,
    required this.playerAuthoredZ,
  })  : _positions = positions,
        _velocities = velocities,
        _playerZ = playerZ,
        _playerZVel = playerZVel;

  /// Snapshot from [doc] at play start.
  factory ScenePlayState.fromDoc(SceneDoc doc) {
    final positions = <String, Offset>{};
    final velocities = <String, Offset>{};
    String? playerId;
    var playerW = 64.0;
    var playerH = 64.0;
    var playerZ = 0.0;
    for (final n in doc.nodes) {
      if (n.isCamera) continue;
      positions[n.id] = Offset(n.x, n.y);
      velocities[n.id] = Offset.zero;
      if (playerId == null && n.name.toLowerCase() == 'player') {
        playerId = n.id;
        playerW = n.w > 0 ? n.w : 64.0;
        playerH = n.h > 0 ? n.h : 64.0;
        playerZ = n.z;
      }
    }
    return ScenePlayState._(
      stageW: doc.width.toDouble(),
      stageH: doc.height.toDouble(),
      positions: positions,
      velocities: velocities,
      playerId: playerId,
      playerW: playerW,
      playerH: playerH,
      playerZ: playerZ,
      playerZVel: 0,
      playerAuthoredZ: playerZ,
    );
  }

  final double stageW;
  final double stageH;
  final String? playerId;

  /// Player node footprint at play start (for stage clamp).
  final double playerW;
  final double playerH;

  /// Authored Z at play start (runtime offset = currentZ - this).
  final double playerAuthoredZ;

  final Map<String, Offset> _positions;
  final Map<String, Offset> _velocities;
  double _playerZ;
  double _playerZVel;

  /// Max simulation step (avoids huge jumps after a hitch). ~1/20 s.
  static const double maxDt = 1.0 / 20.0;

  /// Stage units per second at full stick (XY and Z).
  static const double moveSpeed = 220.0;

  /// Velocity decay when stick released (units/s² toward zero).
  static const double damping = 900.0;

  /// Soft Z range so player stays in a usable depth band (low-end safe).
  static const double zMin = -800.0;
  static const double zMax = 800.0;

  Offset positionOf(String id) => _positions[id] ?? Offset.zero;

  Offset velocityOf(String id) => _velocities[id] ?? Offset.zero;

  /// Runtime world Z for the Player (others use authored node.z).
  double get playerZ => _playerZ;

  /// Authoring pose + runtime offset for drawing (Player moves; others stay).
  Offset runtimeOffset(SceneNode n) {
    if (n.isCamera) return Offset.zero;
    final p = _positions[n.id];
    if (p == null) return Offset.zero;
    return Offset(p.dx - n.x, p.dy - n.y);
  }

  /// Runtime Z offset for drawing/projection (Player only).
  double runtimeZOffset(SceneNode n) {
    if (playerId == null || n.id != playerId) return 0;
    return _playerZ - playerAuthoredZ;
  }

  /// World Z for a node during play (Player uses runtime Z).
  double worldZ(SceneNode n) {
    if (playerId != null && n.id == playerId) return _playerZ;
    return n.z;
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

  /// Integrate one frame.
  /// [steer] XY unit-ish (−1…1), stage axes (y down).
  /// [steerZ] −1…1 (Q/E or future pad); 0 = no depth input.
  void update(double dt, Offset steer, [double steerZ = 0]) {
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

    // Dead-zone 0.05; above it, magnitude shapes speed (partial stick = slower).
    const dead = 0.05;
    if (mag > dead) {
      final shaped = ((mag - dead) / (1.0 - dead)).clamp(0.0, 1.0);
      final inv = 1.0 / mag;
      vel = Offset(sx * inv * shaped * moveSpeed, sy * inv * shaped * moveSpeed);
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

    // Clamp top-left using the player's real footprint.
    const margin = 8.0;
    final maxX = math.max(margin, stageW - playerW - margin);
    final maxY = math.max(margin, stageH - playerH - margin);
    pos = Offset(
      pos.dx.clamp(margin, maxX),
      pos.dy.clamp(margin, maxY),
    );

    // Z axis — same dead-zone / damping feel as XY.
    final sz = steerZ.clamp(-1.0, 1.0);
    if (sz.abs() > dead) {
      final shapedZ = ((sz.abs() - dead) / (1.0 - dead)).clamp(0.0, 1.0);
      _playerZVel = sz.sign * shapedZ * moveSpeed;
    } else {
      final vZ = _playerZVel.abs();
      if (vZ < 1.0) {
        _playerZVel = 0;
      } else {
        final decel = damping * step;
        final scale = math.max(0.0, (vZ - decel) / vZ);
        _playerZVel *= scale;
      }
    }
    _playerZ = (_playerZ + _playerZVel * step).clamp(zMin, zMax);

    _positions[id] = pos;
    _velocities[id] = vel;
  }
}
