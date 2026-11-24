import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_studio/features/workspace/scene/scene_project.dart';

void main() {
  test('projection golden visibility matches Dart SceneProject', () {
    final file = File('test/golden/projection.json');
    expect(file.existsSync(), isTrue, reason: 'golden file missing');
    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final stage = data['stage'] as Map<String, dynamic>;
    final camJson = data['camera'] as Map<String, dynamic>;
    final cam = SceneCamFrame(
      cx: (camJson['cx'] as num).toDouble(),
      cy: (camJson['cy'] as num).toDouble(),
      cz: (camJson['cz'] as num).toDouble(),
      near: (camJson['near'] as num).toDouble(),
      far: (camJson['far'] as num).toDouble(),
      fovDeg: (camJson['fov'] as num).toDouble(),
      stageW: (stage['width'] as num).toDouble(),
      stageH: (stage['height'] as num).toDouble(),
    );
    final cases = data['cases'] as List<dynamic>;
    for (final raw in cases) {
      final c = Map<String, dynamic>.from(raw as Map);
      final mode = c['mode'] == 'ndc'
          ? SceneProjectMode.ndc
          : SceneProjectMode.soft;
      final p = SceneProject.project(
        cam,
        (c['x'] as num).toDouble(),
        (c['y'] as num).toDouble(),
        (c['z'] as num).toDouble(),
        mode: mode,
      );
      expect(
        p.visible,
        c['expect_visible'] as bool,
        reason: c['name'] as String,
      );
    }
  });
}
