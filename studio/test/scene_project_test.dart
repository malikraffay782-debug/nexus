import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_studio/features/workspace/scene/scene_model.dart';
import 'package:nexus_studio/features/workspace/scene/scene_project.dart';

void main() {
  const stageW = 720.0;
  const stageH = 1280.0;

  SceneCamFrame cam({
    double cx = 360,
    double cy = 640,
    double cz = 0,
    double near = 0.1,
    double far = 1000,
    double fov = 60,
  }) {
    return SceneCamFrame(
      cx: cx,
      cy: cy,
      cz: cz,
      near: near,
      far: far,
      fovDeg: fov,
      stageW: stageW,
      stageH: stageH,
    );
  }

  group('SceneProject.soft', () {
    test('point at eye depth projects near center with scale ~1 path', () {
      final c = cam();
      // z = cz → depth 0; soft still treats as visible (inSoftDepth).
      final p = SceneProject.projectSoft(c, c.cx, c.cy, c.cz);
      expect(p.visible, isTrue);
      expect(p.x, closeTo(c.cx, 1e-6));
      expect(p.y, closeTo(c.cy, 1e-6));
    });

    test('farther point scales down and pulls toward camera center', () {
      final c = cam();
      final p = SceneProject.projectSoft(c, c.cx + 200, c.cy + 100, c.cz + 200);
      expect(p.visible, isTrue);
      expect(p.scale, lessThan(1.0));
      expect(p.scale, greaterThan(0.0));
      // Pulled toward center relative to original offset.
      expect((p.x - c.cx).abs(), lessThan(200));
      expect((p.y - c.cy).abs(), lessThan(100));
    });

    test('behind far plane is not visible on soft path', () {
      final c = cam(far: 100);
      final p = SceneProject.projectSoft(c, c.cx, c.cy, c.cz + 500);
      expect(p.visible, isFalse);
    });
  });

  group('SceneProject.ndc frustum', () {
    test('point in front of camera near center is inside frustum', () {
      final c = cam(cz: 0, near: 1, far: 500);
      // Point slightly in front along +Z from eye.
      final ok = SceneProject.inNdcFrustum(c, c.cx, c.cy, c.cz + 50);
      expect(ok, isTrue);
    });

    test('point beyond far is outside', () {
      final c = cam(cz: 0, near: 1, far: 100);
      final ok = SceneProject.inNdcFrustum(c, c.cx, c.cy, c.cz + 500);
      expect(ok, isFalse);
    });

    test('point behind near plane is outside', () {
      final c = cam(cz: 0, near: 10, far: 1000);
      // depth = z - cz = 1 < near
      final ok = SceneProject.inNdcFrustum(c, c.cx, c.cy, c.cz + 1);
      expect(ok, isFalse);
    });
  });

  group('SceneProject.aabbVisible', () {
    test('soft: box overlapping depth range is visible', () {
      final c = cam(cz: 0, far: 200);
      final vis = SceneProject.aabbVisible(
        c,
        300,
        600,
        80,
        80,
        50,
        mode: SceneProjectMode.soft,
      );
      expect(vis, isTrue);
    });

    test('soft: box entirely past far is not visible', () {
      final c = cam(cz: 0, far: 50);
      final vis = SceneProject.aabbVisible(
        c,
        300,
        600,
        80,
        80,
        400,
        mode: SceneProjectMode.soft,
      );
      expect(vis, isFalse);
    });

    test('ndc: small box in front near center is visible', () {
      final c = cam(cz: 0, near: 1, far: 500);
      final vis = SceneProject.aabbVisible(
        c,
        c.cx - 20,
        c.cy - 20,
        40,
        40,
        40,
        mode: SceneProjectMode.ndc,
      );
      expect(vis, isTrue);
    });
  });

  group('SceneCamFrame.fromNodes', () {
    test('prefers preferredId camera when present', () {
      final nodes = [
        const SceneNode(
          id: 'c1',
          type: SceneNodeTypes.camera,
          name: 'Cam A',
          x: 0,
          y: 0,
          w: 48,
          h: 48,
        ),
        const SceneNode(
          id: 'c2',
          type: SceneNodeTypes.camera,
          name: 'Cam B',
          x: 100,
          y: 200,
          w: 48,
          h: 48,
        ),
      ];
      final frame = SceneCamFrame.fromNodes(
        nodes,
        stageW: stageW,
        stageH: stageH,
        preferredId: 'c2',
      );
      expect(frame, isNotNull);
      expect(frame!.cx, closeTo(100 + 24, 1e-6));
      expect(frame.cy, closeTo(200 + 24, 1e-6));
    });

    test('returns null when no camera', () {
      final nodes = [
        const SceneNode(
          id: 's1',
          type: SceneNodeTypes.sprite,
          name: 'Sprite',
          x: 0,
          y: 0,
        ),
      ];
      final frame = SceneCamFrame.fromNodes(
        nodes,
        stageW: stageW,
        stageH: stageH,
      );
      expect(frame, isNull);
    });
  });
}
