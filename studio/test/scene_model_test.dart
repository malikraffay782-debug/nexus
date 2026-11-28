import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_studio/features/workspace/scene/scene_model.dart';

void main() {
  group('SceneNode JSON', () {
    test('round-trip preserves transform and mesh', () {
      const n = SceneNode(
        id: 'n1',
        type: SceneNodeTypes.sprite,
        name: 'Box',
        x: 10,
        y: 20,
        z: 5,
        zDepth: 2,
        rx: 15,
        ry: -30,
        rz: 45,
        w: 64,
        h: 48,
        color: 0xFF42A5F5,
        mesh: SceneMeshes.crate,
      );
      final again = SceneNode.fromJson(n.toJson());
      expect(again.id, n.id);
      expect(again.name, n.name);
      expect(again.x, n.x);
      expect(again.y, n.y);
      expect(again.z, n.z);
      expect(again.zDepth, n.zDepth);
      expect(again.rx, n.rx);
      expect(again.ry, n.ry);
      expect(again.rz, n.rz);
      expect(again.w, n.w);
      expect(again.h, n.h);
      expect(again.mesh, SceneMeshes.crate);
    });

    test('normalizeDegrees wraps and rejects non-finite', () {
      expect(SceneNode.normalizeDegrees(0), 0);
      expect(SceneNode.normalizeDegrees(180), 180);
      expect(SceneNode.normalizeDegrees(181), closeTo(-179, 1e-9));
      expect(SceneNode.normalizeDegrees(360), 0);
      expect(SceneNode.normalizeDegrees(double.nan), 0);
    });

    test('foreshorten never zero', () {
      final a = SceneNode.foreshorten(0, 0);
      expect(a.$1, 1.0);
      expect(a.$2, 1.0);
      final b = SceneNode.foreshorten(90, 90);
      expect(b.$1, greaterThanOrEqualTo(0.22));
      expect(b.$2, greaterThanOrEqualTo(0.22));
    });

    test('camera near/far invariant repaired on load', () {
      final n = SceneNode.fromJson({
        'id': 'c1',
        'type': 'camera',
        'name': 'Cam',
        'x': 0,
        'y': 0,
        'w': 48,
        'h': 48,
        'near': -5,
        'far': 1,
      });
      expect(n.near, greaterThan(0));
      expect(n.far, greaterThan(n.near));
    });
  });

  group('SceneDoc JSON', () {
    test('save→load round trip', () {
      final doc = SceneDoc(
        name: 'test_scene',
        width: 800,
        height: 600,
        showGrid: true,
        nodes: const [
          SceneNode(
            id: 'p1',
            type: SceneNodeTypes.sprite,
            name: 'Player',
            x: 100,
            y: 200,
            mesh: SceneMeshes.sword,
          ),
          SceneNode(
            id: 'cam',
            type: SceneNodeTypes.camera,
            name: 'Main',
            x: 50,
            y: 50,
            w: 48,
            h: 48,
            fov: 50,
          ),
        ],
      );
      final text = doc.encodePretty();
      final loaded = SceneDoc.decode(text);
      expect(loaded.name, doc.name);
      expect(loaded.width, 800);
      expect(loaded.height, 600);
      expect(loaded.showGrid, isTrue);
      expect(loaded.nodes.length, 2);
      expect(loaded.nodes[0].name, 'Player');
      expect(loaded.nodes[0].mesh, SceneMeshes.sword);
      expect(loaded.nodes[1].isCamera, isTrue);
      expect(loaded.nodes[1].fov, 50);
    });

    test('duplicate ids are uniquified on load', () {
      final loaded = SceneDoc.fromJson({
        'name': 'dup',
        'nodes': [
          {'id': 'same', 'type': 'sprite', 'name': 'A', 'x': 0, 'y': 0},
          {'id': 'same', 'type': 'sprite', 'name': 'B', 'x': 1, 'y': 1},
        ],
      });
      expect(loaded.nodes.length, 2);
      expect(loaded.nodes[0].id, isNot(equals(loaded.nodes[1].id)));
    });
  });

  group('SceneMeshes', () {
    test('normalize unknown to none', () {
      expect(SceneMeshes.normalize(null), SceneMeshes.none);
      expect(SceneMeshes.normalize('crate'), SceneMeshes.crate);
      expect(SceneMeshes.normalize('nope'), SceneMeshes.none);
    });
  });

  group('SceneSprites', () {
    test('normalize accepts assets png only', () {
      expect(SceneSprites.normalize('assets/hero.png'), 'assets/hero.png');
      expect(SceneSprites.normalize('assets/../x.png'), SceneSprites.none);
      expect(SceneSprites.normalize('/abs.png'), SceneSprites.none);
      expect(SceneSprites.normalize('src/x.png'), SceneSprites.none);
      expect(SceneSprites.normalize('assets/x.gif'), SceneSprites.none);
    });
  });
}
