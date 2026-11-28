import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_studio/features/workspace/scene/scene_mesh_wire.dart';
import 'package:nexus_studio/features/workspace/scene/scene_model.dart';

void main() {
  group('SceneMeshWire', () {
    test('known meshes expose edges', () {
      expect(SceneMeshWire.edgeCount(SceneMeshes.crate), 12);
      expect(SceneMeshWire.edgeCount(SceneMeshes.metalcase), 12);
      expect(SceneMeshWire.edgeCount(SceneMeshes.chest), greaterThan(4));
      expect(SceneMeshWire.edgeCount(SceneMeshes.sword), greaterThan(6));
      expect(SceneMeshWire.edgeCount(SceneMeshes.none), 0);
      expect(SceneMeshWire.edgeCount('nope'), 0);
    });

    test('metalcase has extra X braces', () {
      expect(SceneMeshWire.extraEdges(SceneMeshes.metalcase).length, 2);
      expect(SceneMeshWire.extraEdges(SceneMeshes.crate), isEmpty);
    });

    test('unit points stay bounded', () {
      for (final id in SceneMeshes.all) {
        if (id.isEmpty) continue;
        expect(SceneMeshWire.unitBoundsOk(id), isTrue, reason: id);
      }
    });

    test('fill paths exist for body meshes', () {
      expect(SceneMeshWire.fillPath(SceneMeshes.crate), isNotNull);
      expect(SceneMeshWire.fillPath(SceneMeshes.sword), isNotNull);
      expect(SceneMeshWire.fillPath(SceneMeshes.none), isNull);
    });

    test('mapPoint scales unit to pixels', () {
      final p = SceneMeshWire.mapPoint(const Offset(1, -1), 40, 20);
      expect(p.dx, 40);
      expect(p.dy, -20);
    });
  });

  test('box meshes flagged for projected path', () {
    expect(SceneMeshWire.isBoxMesh(SceneMeshes.crate), isTrue);
    expect(SceneMeshWire.isBoxMesh(SceneMeshes.metalcase), isTrue);
    expect(SceneMeshWire.isBoxMesh(SceneMeshes.sword), isFalse);
    expect(SceneMeshWire.boxEdgeIndices.length, 12);
  });

  test('sword and chest have planar edges for projected path', () {
    expect(SceneMeshWire.edges(SceneMeshes.sword), isNotEmpty);
    expect(SceneMeshWire.edges(SceneMeshes.chest), isNotEmpty);
    expect(SceneMeshWire.isBoxMesh(SceneMeshes.sword), isFalse);
    expect(SceneMeshWire.isBoxMesh(SceneMeshes.chest), isFalse);
  });
}
