import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/project.dart';

class ProjectRepository {
  static const _manifest = 'project.json';

  Future<Directory> _root() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'projects'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } on FileSystemException catch (e) {
      throw StateError('Projects folder unavailable: ${e.message}');
    } catch (e) {
      throw StateError('Projects folder unavailable: $e');
    }
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
    } catch (_) {}
    return dir;
  }

  Future<Project?> _readFrom(Directory dir) async {
    final file = File(p.join(dir.path, _manifest));
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return Project.fromJson(json, path: dir.path);
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
        } catch (_) {}
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

    await dir.create(recursive: true);

    try {
      for (final sub in [
        'src',
        'assets',
        type == ProjectType.game ? 'scenes' : 'screens',
      ]) {
        await Directory(p.join(dir.path, sub)).create();
      }

      final project = Project(
        id: id,
        name: name.trim(),
        type: type,
        createdAt: DateTime.now(),
        path: dir.path,
      );

      final tmpPath = p.join(
        dir.path,
        'project.json.${Random.secure().nextInt(1 << 30)}.tmp',
      );
      final tmp = File(tmpPath);
      final manifest = File(p.join(dir.path, _manifest));
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(project.toJson()),
        flush: true,
      );
      if (await manifest.exists()) {
        try {
          await tmp.rename(manifest.path);
        } on FileSystemException {
          await tmp.copy(manifest.path);
          await tmp.delete();
        }
      } else {
        await tmp.rename(manifest.path);
      }

      return project;
    } catch (e) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    final dir = await _dirFor(id);
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<bool> exists(String id) async {
    final dir = await _dirFor(id);
    if (dir == null || !await dir.exists()) return false;
    return File(p.join(dir.path, _manifest)).exists();
  }
}
