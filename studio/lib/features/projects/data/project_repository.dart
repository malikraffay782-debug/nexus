import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/project.dart';

/// Projects live at `<app documents>/projects/<id>/project.json`.
class ProjectRepository {
  static const _manifest = 'project.json';

  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'projects'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> rootPath() async => (await _root()).path;

  Future<Directory?> _dirFor(String id) async {
    if (id.isEmpty ||
        id.contains('/') ||
        id.contains(r'\') ||
        id.contains('..')) {
      return null;
    }
    final root = await _root();
    return Directory(p.join(root.path, id));
  }

  Future<Project?> _readFrom(Directory dir) async {
    final file = File(p.join(dir.path, _manifest));
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return Project.fromJson(json, path: dir.path);
    } catch (_) {
      return null;
    }
  }

  Future<List<Project>> list() async {
    final root = await _root();
    final projects = <Project>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final project = await _readFrom(entity);
      if (project != null) projects.add(project);
    }
    projects.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return projects;
  }

  Future<Project?> getById(String id) async {
    final dir = await _dirFor(id);
    if (dir == null || !await dir.exists()) return null;
    return _readFrom(dir);
  }

  Future<Project> create({
    required String name,
    required ProjectType type,
  }) async {
    final root = await _root();
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final dir = Directory(p.join(root.path, id));
    await dir.create(recursive: true);

    final subfolders = [
      'src',
      'assets',
      type == ProjectType.game ? 'scenes' : 'screens',
    ];
    for (final sub in subfolders) {
      await Directory(p.join(dir.path, sub)).create();
    }

    final project = Project(
      id: id,
      name: name.trim(),
      type: type,
      createdAt: DateTime.now(),
      path: dir.path,
    );
    await File(p.join(dir.path, _manifest)).writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
    );
    return project;
  }

  Future<void> delete(String id) async {
    final dir = await _dirFor(id);
    if (dir != null && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
