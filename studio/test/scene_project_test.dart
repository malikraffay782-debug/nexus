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
    test('look +Z: center at depth 50 has clip w > 0 and is inside frustum',
        () {
      final c = cam(cz: 0, near: 1, far: 500);
      final depth = 50.0;
      final worldZ = c.cz + depth;
      // Raw VP must produce positive w for points in front (look +Z).
      final vp = c.viewProjectionMatrix();
      final clip = vp.transformPoint(c.cx, c.cy, worldZ);
      expect(clip.$4, greaterThan(0),
          reason: 'clip w must be +depth for look +Z, not OpenGL −z');
      final ndc = SceneProject.toNdc(c, c.cx, c.cy, worldZ, viewProjection: vp);
      expect(ndc, isNotNull);
      expect(ndc!.$1, closeTo(0, 0.05));
      expect(ndc.$2, closeTo(0, 0.05));
      expect(SceneProject.inNdcFrustum(c, c.cx, c.cy, worldZ), isTrue);
    });

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


  group('SceneProject.ndc project consistency', () {
    test('off-center point stays visible and scale uses 1/depth', () {
      final c = cam(cz: -240, near: 1, far: 2000);
      final z = 0.0; // depth = 240
      final p = SceneProject.project(
        c,
        c.cx + 30,
        c.cy + 20,
        z,
        mode: SceneProjectMode.ndc,
      );
      expect(p.visible, isTrue);
      final depth = c.depthOf(z);
      expect(p.scale, closeTo(SceneProject.perspectiveScale(c, depth), 1e-6));
      expect(p.scale, isNot(closeTo(SceneProject.depthScale(c, depth), 1e-3)));
    });

    test('rotated camera still projects center in front', () {
      final c = SceneCamFrame(
        cx: 360,
        cy: 640,
        cz: -200,
        near: 1,
        far: 2000,
        fovDeg: 60,
        stageW: stageW,
        stageH: stageH,
        rx: 8,
        ry: -12,
        rz: 5,
      );
      final ok = SceneProject.inNdcFrustum(c, 360, 640, 0);
      expect(ok, isTrue);
      final p = SceneProject.project(c, 360, 640, 0, mode: SceneProjectMode.ndc);
      expect(p.visible, isTrue);
    });

    test('behind camera is culled', () {
      final c = cam(cz: 0, near: 1, far: 500);
      // world z behind eye → depth negative
      final p = SceneProject.project(
        c,
        c.cx,
        c.cy,
        c.cz - 10,
        mode: SceneProjectMode.ndc,
      );
      expect(p.visible, isFalse);
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
      // At depth 200, a 10×10 stage box stays inside 60° FOV lateral bounds.
      final vis = SceneProject.aabbVisible(
        c,
        c.cx - 5,
        c.cy - 5,
        10,
        10,
        200,
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
