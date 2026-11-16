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
    } catch (e) {
      // Path resolution failed — treat as unavailable id.
      assert(() {
        // ignore: avoid_print
        print('ProjectRepository._dirFor skip: $e');
        return true;
      }());
      return null;
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
        assert(() {
          // ignore: avoid_print
          print(
            'Nexus: skip project with id mismatch at ${dir.path}: '
            'manifest=${project.id} dir=$dirId',
          );
          return true;
        }());
        return null;
      }
      return project;
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('Nexus: skip corrupt project at ${dir.path}: $e');
        return true;
      }());
      return null;
    }
  }

  Future<List<Project>> list() async {
    // Let storage failure bubble so UI can show AsyncError (not fake empty list)
    final root = await _root();
    await _sweepStaleStaging(root);
    final projects = <Project>[];
    try {
      await for (final entity in root.list(followLinks: false)) {
        try {
          if (entity is! Directory) continue;
          if (await _isSymlink(entity)) continue;
          final project = await _readFrom(entity);
          if (project != null) projects.add(project);
        } catch (e) {
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


  /// Remove leftover `.$id.staging` dirs older than 1 hour (create failure orphans).
  Future<void> _sweepStaleStaging(Directory root) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('.') || !name.endsWith('.staging')) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete(recursive: true);
          }
        } catch (_) {}
      }
    } catch (_) {}
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

from scene_draw import load_scene, draw_scene, export_mesh_stub

def main():
    scene = load_scene("scenes/main.json")
    draw_scene(scene)
    export_mesh_stub(scene)

if __name__ == "__main__":
    main()
''';

/// Minimal scene JSON reader + ASCII stage for embedded runtime.
const String _kSceneDrawPy = r'''"""Load Nexus scene JSON and print a text stage (2D + 3D foundation)."""
from __future__ import annotations

import json
import math
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
    z = float(node.get("z") or 0)
    w = int(float(node.get("w") or 0))
    h = int(float(node.get("h") or 0))
    pts = node.get("points")
    extra = f" poly:{len(pts)}" if isinstance(pts, list) and len(pts) >= 3 else ""
    mesh = str(node.get("mesh") or "").strip()
    if mesh and ntype != "camera":
        extra = f"{extra} mesh={mesh}"
    zpart = f" z={z:g}" if z else ""
    if ntype == "camera":
        fov = float(node.get("fov") or 60)
        near = float(node.get("near") or 0.1)
        far = float(node.get("far") or 1000)
        extra = f" fov={fov:g} near={near:g} far={far:g}"
    return f"{name} [{ntype}] @({x},{y}){zpart} {w}x{h}{extra}"


def _active_camera(nodes: list) -> dict | None:
    for n in nodes:
        if isinstance(n, dict) and str(n.get("type") or "") == "camera":
            return n
    return None


def _cam_params(cam: dict) -> tuple[float, float, float, float, float, float]:
    """Unpack camera node → (cx, cy, cz, fov, near, far)."""
    cx = float(cam.get("x") or 0) + float(cam.get("w") or 0) * 0.5
    cy = float(cam.get("y") or 0) + float(cam.get("h") or 0) * 0.5
    cz = float(cam.get("z") or 0)
    fov = float(cam.get("fov") or 60)
    near = max(float(cam.get("near") or 0.1), 0.01)
    far = max(float(cam.get("far") or 1000), near + 0.01)
    return cx, cy, cz, fov, near, far


def _camera_space_depth(z: float, cz: float) -> float:
    """(1) Camera space: eye at cz, look +Z. Positive depth = in front."""
    return z - cz


def _in_depth_frustum(depth: float, near: float, far: float) -> bool:
    """(3) Depth-slab cull. Full 6-plane FOV cone waits on a real clip matrix."""
    return near <= depth <= far


def _project_xy(
    x: float,
    y: float,
    z: float,
    width: float,
    height: float,
    params: tuple[float, float, float, float, float, float] | None,
    *,
    skip_cull: bool = False,
) -> tuple[float, float, bool]:
    """(2) Soft clip-space scale toward camera center.

    params = (cx, cy, cz, fov, near, far) from _cam_params, or None = ortho.
    skip_cull=True when the caller already depth-filtered the node (hot path).

    Full path later: world → camera → projection matrix → NDC.
    Returns (sx, sy, visible).
    """
    if params is None:
        return x, y, True
    cx, cy, cz, fov, near, far = params
    depth = _camera_space_depth(z, cz)
    if not skip_cull and not _in_depth_frustum(depth, near, far):
        return x, y, False
    # Wider FOV → stronger shrink with depth (clamped for ASCII readability).
    fov_k = max(0.35, min(2.5, fov / 60.0))
    ref = max(width, height) * 0.35
    scale = ref / (ref + max(depth, near) * fov_k)
    sx = cx + (x - cx) * scale
    sy = cy + (y - cy) * scale
    return sx, sy, True


def draw_scene(scene: dict) -> None:
    width = int(scene.get("width") or 720)
    height = int(scene.get("height") or 1280)
    name = str(scene.get("name") or "scene")
    nodes = scene.get("nodes") or []
    if not isinstance(nodes, list):
        nodes = []

    cam = _active_camera(nodes)
    # Hoist camera unpack once for the whole frame.
    params = _cam_params(cam) if cam is not None else None
    mode = "perspective" if params is not None else "ortho"
    print(f"Nexus scene: {name}  {width}x{height}  [{mode}]")
    if params is not None:
        _cx, _cy, cz, _fov, near, far = params
        print(f"active camera: {_node_label(cam)}")
        print(f"camera space: look +Z  eye_z={cz:g}  near={near:g}  far={far:g}")
    print(f"nodes: {len(nodes)} (depth sort by z, far→near)")
    if not nodes:
        print("(empty stage)")
        return

    # Pre-filter: one depth test per node, then sort only survivors.
    visible: list = []
    culled_labels: list[str] = []
    for n in nodes:
        if not isinstance(n, dict) or str(n.get("type") or "") == "camera":
            continue
        if params is not None:
            z = float(n.get("z") or 0)
            _cx, _cy, cz, _fov, near, far = params
            if not _in_depth_frustum(_camera_space_depth(z, cz), near, far):
                culled_labels.append(_node_label(n))
                continue
        visible.append(n)
    visible.sort(key=lambda n: float(n.get("z") or 0))

    cols, rows = 24, 12
    grid = [["." for _ in range(cols)] for _ in range(rows)]

    def to_cell(px: float, py: float) -> tuple[int, int]:
        c = int(px / width * (cols - 1)) if width > 0 else 0
        r = int(py / height * (rows - 1)) if height > 0 else 0
        c = max(0, min(cols - 1, c))
        r = max(0, min(rows - 1, r))
        return c, r

    for idx, node in enumerate(visible):
        ch = str(idx % 10)
        z = float(node.get("z") or 0)
        pts = node.get("points")
        if isinstance(pts, list) and len(pts) >= 3:
            coords = []
            for pt in pts:
                if not isinstance(pt, dict):
                    continue
                px = float(pt.get("x") or 0)
                py = float(pt.get("y") or 0)
                sx, sy, _vis = _project_xy(
                    px, py, z, width, height, params, skip_cull=True
                )
                coords.append(to_cell(sx, sy))
                c, r = coords[-1]
                grid[r][c] = "#"
            for i in range(len(coords)):
                c0, r0 = coords[i]
                c1, r1 = coords[(i + 1) % len(coords)]
                steps = max(abs(c1 - c0), abs(r1 - r0), 1)
                for s in range(steps + 1):
                    t = s / steps
                    cc = int(round(c0 + (c1 - c0) * t))
                    rr = int(round(r0 + (r1 - r0) * t))
                    if grid[rr][cc] == ".":
                        grid[rr][cc] = ch
            continue
        x = float(node.get("x") or 0)
        y = float(node.get("y") or 0)
        w = max(float(node.get("w") or 1), 1.0)
        h = max(float(node.get("h") or 1), 1.0)
        corners = [
            _project_xy(x, y, z, width, height, params, skip_cull=True)[:2],
            _project_xy(x + w, y, z, width, height, params, skip_cull=True)[:2],
            _project_xy(x + w, y + h, z, width, height, params, skip_cull=True)[:2],
            _project_xy(x, y + h, z, width, height, params, skip_cull=True)[:2],
        ]
        cs = [to_cell(px, py) for px, py in corners]
        c0 = min(c for c, _ in cs)
        c1 = max(c for c, _ in cs)
        r0 = min(r for _, r in cs)
        r1 = max(r for _, r in cs)
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                grid[r][c] = ch

    # Mark camera cell with C
    if params is not None:
        cx, cy, _cz, _fov, _near, _far = params
        cc, rr = to_cell(cx, cy)
        grid[rr][cc] = "C"

    print("+" + "-" * cols + "+")
    for row in grid:
        print("|" + "".join(row) + "|")
    print("+" + "-" * cols + "+")
    if culled_labels:
        print(f"culled: {len(culled_labels)} (outside camera near/far)")
        for label in culled_labels:
            print(f"  culled: {label}")
    for i, node in enumerate(nodes):
        if isinstance(node, dict):
            print(f"  {i}: {_node_label(node)}")


# GameAssets.hpp makers (samples/cpp) — runtime export stub only.
_MESH_MAKERS = {
    "sword": "ga::makeSword()",
    "crate": "ga::makeWoodenCrate()",
    "chest": "ga::makeTreasureChest()",
    "metalcase": "ga::makeMetalCase()",
}


def _collect_mesh_ids(nodes: list) -> list[str]:
    seen: list[str] = []
    for n in nodes:
        if not isinstance(n, dict):
            continue
        if str(n.get("type") or "") == "camera":
            continue
        mid = str(n.get("mesh") or "").strip().lower()
        if mid and mid in _MESH_MAKERS and mid not in seen:
            seen.append(mid)
    return seen


def export_mesh_stub(scene: dict, rel_dir: str = "assets/meshes") -> None:
    """Write a manifest of linked mesh ids for later C++ / runtime sample use.

    Does not compile or copy geometry — only records which GameAssets makers
    the scene needs so a future pack step can pull samples/cpp.
    """
    nodes = scene.get("nodes") or []
    if not isinstance(nodes, list):
        nodes = []
    ids = _collect_mesh_ids(nodes)
    print("--- mesh export stub ---")
    if not ids:
        print("(no mesh ids linked on sprites)")
        return
    out_dir = Path(rel_dir)
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        print(f"mesh stub: could not create {out_dir}: {e}")
        return
    entries = []
    for mid in ids:
        maker = _MESH_MAKERS[mid]
        entries.append({
            "id": mid,
            "maker": maker,
            "header": "samples/cpp/GameAssets.hpp",
            "status": "stub",
        })
        print(f"  {mid} -> {maker}  [stub]")
    manifest = {
        "version": 1,
        "source": "scenes/main.json",
        "meshes": entries,
        "note": "Stub only — geometry not exported. Link C++17 sample later.",
    }
    path = out_dir / "manifest.json"
    try:
        path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {path}")
    except OSError as e:
        print(f"mesh stub: write failed: {e}")


def main() -> None:
    scene = load_scene("scenes/main.json")
    draw_scene(scene)
    export_mesh_stub(scene)


if __name__ == "__main__":
    main()
''';
