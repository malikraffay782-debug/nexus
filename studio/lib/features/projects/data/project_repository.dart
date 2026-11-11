import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/project.dart';
import '../../../services/embedded_runtime.dart';

class ProjectRepository {
  static const _manifest = 'project.json';

  Future<Directory> _root() async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        // Prefer native path so Flutter and proot always share one projects root.
        final nativeRoot = await EmbeddedRuntime.getProjectsRoot();
        final dir = nativeRoot != null && nativeRoot.isNotEmpty
            ? Directory(nativeRoot)
            : Directory(
                p.join((await getApplicationDocumentsDirectory()).path, 'projects'),
              );
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return dir;
      } on FileSystemException catch (e) {
        lastError = e;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }
      } catch (e) {
        lastError = e;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }
      }
    }
    throw StateError('Projects folder unavailable: $lastError');
  }

  Future<String> rootPath() async => (await _root()).path;

  bool _isSafeId(String id) {
    if (id.isEmpty || id.length > 64) return false;
    return Project.idPattern.hasMatch(id);
  }

  Future<bool> _isSymlink(FileSystemEntity entity) async {
    try {
      return await FileSystemEntity.isLink(entity.path);
    } catch (_) {
      return false;
    }
  }

  Future<Directory?> _dirFor(String id) async {
    if (!_isSafeId(id)) return null;
    final root = await _root();
    final dir = Directory(p.join(root.path, id));
    if (await _isSymlink(dir)) return null;
    try {
      final rootReal = await root.resolveSymbolicLinks();
      if (await dir.exists()) {
        final dirReal = await dir.resolveSymbolicLinks();
        if (!p.equals(dirReal, rootReal) && !p.isWithin(rootReal, dirReal)) {
          return null;
        }
      }
    } catch (e, st) {
          // Ignore unreadable entries but keep a debug trace.
          assert(() {
            // ignore: avoid_print
            print('ProjectRepository.list skip: $e');
            return true;
          }());
        }
    return dir;
  }

  Future<Project?> _readFrom(Directory dir) async {
    final file = File(p.join(dir.path, _manifest));
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final project = Project.fromJson(json, path: dir.path);
      final dirId = p.basename(dir.path);
      if (project.id != dirId) {
        // ignore: avoid_print
        print(
          'Nexus: skip project with id mismatch at ${dir.path}: '
          'manifest=${project.id} dir=$dirId',
        );
        return null;
      }
      return project;
    } catch (e) {
      // ignore: avoid_print
      print('Nexus: skip corrupt project at ${dir.path}: $e');
      return null;
    }
  }

  Future<List<Project>> list() async {
    // Let storage failure bubble so UI can show AsyncError (not fake empty list)
    final root = await _root();
    final projects = <Project>[];
    try {
      await for (final entity in root.list(followLinks: false)) {
        try {
          if (entity is! Directory) continue;
          if (await _isSymlink(entity)) continue;
          final project = await _readFrom(entity);
          if (project != null) projects.add(project);
        } catch (e, st) {
          // Ignore unreadable entries but keep a debug trace.
          assert(() {
            // ignore: avoid_print
            print('ProjectRepository.list skip: $e');
            return true;
          }());
        }
      }
    } on FileSystemException catch (e) {
      throw StateError('Could not read projects: ${e.message}');
    }
    projects.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return projects;
  }

  Future<Project?> getById(String id) async {
    final dir = await _dirFor(id);
    if (dir == null || !await dir.exists()) return null;
    if (await _isSymlink(dir)) return null;
    return _readFrom(dir);
  }

  String _newId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rnd = Random.secure().nextInt(1 << 32).toRadixString(36);
    return '${ts}_$rnd';
  }

  Future<Project> create({
    required String name,
    required ProjectType type,
  }) async {
    final nameErr = Project.validateName(name);
    if (nameErr != null) throw ArgumentError(nameErr);

    final root = await _root();
    Directory? dir;
    var id = _newId();

    for (var attempt = 0; attempt < 5; attempt++) {
      id = attempt == 0 ? id : _newId();
      dir = Directory(p.join(root.path, id));
      if (!await dir.exists()) break;
      dir = null;
    }
    if (dir == null) {
      throw StateError('Could not allocate unique project id');
    }

    // Build fully under a hidden temp name, then rename into final id
    final staging = Directory(p.join(root.path, '.$id.staging'));
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);

    try {
      for (final sub in [
        'src',
        'assets',
        'notes',
        type == ProjectType.game ? 'scenes' : 'screens',
      ]) {
        await Directory(p.join(staging.path, sub)).create();
      }
      if (type == ProjectType.game) {
        await File(p.join(staging.path, 'src', 'scene_draw.py')).writeAsString(
          _kSceneDrawPy,
        );
        await File(p.join(staging.path, 'src', 'main.py')).writeAsString(
          _kGameMainPy,
        );
        await File(p.join(staging.path, 'scenes', 'main.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'version': 1,
            'name': 'main',
            'width': 720,
            'height': 1280,
            'showGrid': true,
            'nodes': <dynamic>[],
          }),
          flush: true,
        );
      } else {
        await File(p.join(staging.path, 'src', 'main.py')).writeAsString(
          "# Nexus project\n"
          "print('hello from nexus')\n",
        );
      }

      final project = Project(
        id: id,
        name: name.trim(),
        type: type,
        createdAt: DateTime.now(),
        path: dir!.path, // final path after rename
      );

      final manifest = File(p.join(staging.path, _manifest));
      await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert(project.toJson()),
        flush: true,
      );

      // Refuse clobber if another process created final path
      if (await dir!.exists()) {
        throw StateError('Project id collision at publish time');
      }
      await staging.rename(dir.path);
      return project.copyWithPath(dir.path);
    } catch (e) {
      // Only clean our staging dir. Never delete [dir] — on a publish race
      // it may belong to another concurrent create for the same id.
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {
        // Preserve the original creation error.
      }
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    final dir = await _dirFor(id);
    if (dir == null) return;
    // Re-check immediately before destructive action
    if (await _isSymlink(dir)) {
      throw StateError('Refusing to delete symlinked project path');
    }
    if (!await dir.exists()) return;
    final root = await _root();
    final rootReal = await root.resolveSymbolicLinks();
    final dirReal = await dir.resolveSymbolicLinks();
    if (!p.isWithin(rootReal, dirReal) && !p.equals(rootReal, dirReal)) {
      throw StateError('Refusing to delete path outside projects root');
    }
    await Directory(dirReal).delete(recursive: true);
  }

  Future<bool> exists(String id) async {
    final dir = await _dirFor(id);
    if (dir == null || !await dir.exists()) return false;
    return File(p.join(dir.path, _manifest)).exists();
  }
}

/// Default game entry: load scenes/main.json and text-draw nodes.
const String _kGameMainPy = r'''
import sys
from pathlib import Path

# Ensure src/ is importable when run as /home/project/src/main.py
sys.path.insert(0, str(Path(__file__).resolve().parent))

from scene_draw import load_scene, draw_scene

def main():
    scene = load_scene("scenes/main.json")
    draw_scene(scene)

if __name__ == "__main__":
    main()
''';

/// Minimal scene JSON reader + ASCII stage for embedded runtime.
const String _kSceneDrawPy = r'''
"""Load Nexus scene JSON and print a simple text stage (no GUI yet)."""
from __future__ import annotations

import json
from pathlib import Path


def load_scene(rel_path: str = "scenes/main.json") -> dict:
    path = Path(rel_path)
    if not path.is_file():
        raise FileNotFoundError(f"Scene not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("Scene root must be an object")
    return data


def _node_label(node: dict) -> str:
    name = str(node.get("name") or "node")
    ntype = str(node.get("type") or "sprite")
    x = int(float(node.get("x") or 0))
    y = int(float(node.get("y") or 0))
    w = int(float(node.get("w") or 0))
    h = int(float(node.get("h") or 0))
    pts = node.get("points")
    extra = f" poly:{len(pts)}" if isinstance(pts, list) and len(pts) >= 3 else ""
    return f"{name} [{ntype}] @({x},{y}) {w}x{h}{extra}"


def draw_scene(scene: dict) -> None:
    width = int(scene.get("width") or 720)
    height = int(scene.get("height") or 1280)
    name = str(scene.get("name") or "scene")
    nodes = scene.get("nodes") or []
    if not isinstance(nodes, list):
        nodes = []

    print(f"Nexus scene: {name}  {width}x{height}")
    print(f"nodes: {len(nodes)} (paint order = list order, last on top)")
    if not nodes:
        print("(empty stage)")
        return

    cols, rows = 24, 12
    grid = [["." for _ in range(cols)] for _ in range(rows)]
    for idx, node in enumerate(nodes):
        if not isinstance(node, dict):
            continue
        x = float(node.get("x") or 0)
        y = float(node.get("y") or 0)
        w = max(float(node.get("w") or 1), 1.0)
        h = max(float(node.get("h") or 1), 1.0)
        c0 = int(x / width * (cols - 1)) if width > 0 else 0
        r0 = int(y / height * (rows - 1)) if height > 0 else 0
        c1 = int((x + w) / width * (cols - 1)) if width > 0 else c0
        r1 = int((y + h) / height * (rows - 1)) if height > 0 else r0
        c0 = max(0, min(cols - 1, c0))
        c1 = max(0, min(cols - 1, c1))
        r0 = max(0, min(rows - 1, r0))
        r1 = max(0, min(rows - 1, r1))
        ch = str(idx % 10)
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                grid[r][c] = ch

    print("+" + "-" * cols + "+")
    for row in grid:
        print("|" + "".join(row) + "|")
    print("+" + "-" * cols + "+")
    for i, node in enumerate(nodes):
        if isinstance(node, dict):
            print(f"  {i}: {_node_label(node)}")
''';
