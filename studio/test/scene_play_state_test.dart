import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_studio/features/workspace/scene/scene_model.dart';
import 'package:nexus_studio/features/workspace/scene/scene_play_state.dart';

void main() {
  SceneDoc docWithPlayer() {
    return SceneDoc(
      name: 'play',
      width: 720,
      height: 1280,
      nodes: const [
        SceneNode(
          id: 'p1',
          type: SceneNodeTypes.sprite,
          name: 'Player',
          x: 100,
          y: 200,
          w: 64,
          h: 64,
        ),
        SceneNode(
          id: 's2',
          type: SceneNodeTypes.sprite,
          name: 'Crate',
          x: 300,
          y: 400,
        ),
      ],
    );
  }

  test('moves while steered and does not snap back on release', () {
    final state = ScenePlayState.fromDoc(docWithPlayer());
    final start = state.positionOf('p1');
    state.update(0.1, const Offset(1, 0));
    final mid = state.positionOf('p1');
    expect(mid.dx, greaterThan(start.dx));
    // Release stick: position must not jump back to authored pose.
    state.update(0.05, Offset.zero);
    final after = state.positionOf('p1');
    expect(after.dx, greaterThan(start.dx));
    expect((after.dx - mid.dx).abs(), lessThan(50));
  });

  test('stays inside stage bounds', () {
    final state = ScenePlayState.fromDoc(docWithPlayer());
    for (var i = 0; i < 40; i++) {
      state.update(0.1, const Offset(1, 1));
    }
    final p = state.positionOf('p1');
    expect(p.dx, lessThan(720));
    expect(p.dy, lessThan(1280));
    expect(p.dx, greaterThan(0));
    expect(p.dy, greaterThan(0));
  });

  test('dt clamp limits huge steps', () {
    final state = ScenePlayState.fromDoc(docWithPlayer());
    final start = state.positionOf('p1');
    // Pathological 5s frame must not teleport farther than maxDt allows.
    state.update(5.0, const Offset(1, 0));
    final p = state.positionOf('p1');
    final maxTravel = ScenePlayState.moveSpeed * ScenePlayState.maxDt + 1;
    expect(p.dx - start.dx, lessThan(maxTravel));
  });

  test('non-player nodes do not move from steer', () {
    final state = ScenePlayState.fromDoc(docWithPlayer());
    final start = state.positionOf('s2');
    state.update(0.2, const Offset(1, 0));
    expect(state.positionOf('s2'), start);
  });

  test('B9: partial stick is slower than full stick', () {
    final full = ScenePlayState.fromDoc(docWithPlayer());
    final half = ScenePlayState.fromDoc(docWithPlayer());
    full.update(0.1, const Offset(1, 0));
    half.update(0.1, const Offset(0.5, 0));
    final fullDx = full.positionOf('p1').dx - 100;
    final halfDx = half.positionOf('p1').dx - 100;
    expect(halfDx, greaterThan(0));
    expect(halfDx, lessThan(fullDx));
  });

  test('B8: clamp uses real player size so large sprite stays on stage', () {
    final doc = SceneDoc(
      name: 'big',
      width: 720,
      height: 1280,
      nodes: const [
        SceneNode(
          id: 'p1',
          type: SceneNodeTypes.sprite,
          name: 'Player',
          x: 100,
          y: 200,
          w: 200,
          h: 200,
        ),
      ],
    );
    final state = ScenePlayState.fromDoc(doc);
    for (var i = 0; i < 80; i++) {
      state.update(0.1, const Offset(1, 1));
    }
    final p = state.positionOf('p1');
    expect(p.dx + 200, lessThanOrEqualTo(720 - 8 + 0.5));
    expect(p.dy + 200, lessThanOrEqualTo(1280 - 8 + 0.5));
  });

}
