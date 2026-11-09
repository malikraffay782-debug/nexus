import 'dart:io';

import '../files/workspace_paths.dart';
import 'scene_model.dart';

/// Read/write scene JSON under the project's scenes/ folder only.
class SceneService {
  SceneService(String projectPath) : paths = WorkspacePaths(projectPath);

  final WorkspacePaths paths;

  static const String rootRel = 'scenes';

  /// Lists scene file names (without path), e.g. ["main.json"].
  Future<List<String>> listScenes() async {
    final abs = paths.resolve(rootRel);
    final dir = Directory(abs);
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {
        return [];
      }
      return [];
    }

    final names = <String>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.isNotEmpty
          ? e.uri.pathSegments.last
          : e.path.split('/').last;
      if (!name.endsWith('.json')) continue;
      if (!WorkspacePaths.isValidSegment(name)) continue;
      names.add(name);
    }
    names.sort();
    return names;
  }

  Future<SceneDoc> load(String fileName) async {
    final rel = '$rootRel/${_validatedName(fileName)}';
    final abs = paths.resolve(rel);
    final file = File(abs);
    if (!await file.exists()) {
      throw const WorkspaceException('Scene file not found');
    }
    final text = await file.readAsString();
    return SceneDoc.decode(text);
  }

  Future<void> save(String fileName, SceneDoc doc) async {
    final rel = '$rootRel/${_validatedName(fileName)}';
    final abs = paths.resolve(rel);
    final file = File(abs);
    await file.parent.create(recursive: true);
    await file.writeAsString(doc.encodePretty(), flush: true);
  }

  /// Creates a new empty scene. Returns the file name (e.g. "level1.json").
  Future<String> create(String rawName) async {
    var base = rawName.trim();
    if (base.endsWith('.json')) {
      base = base.substring(0, base.length - 5);
    }
    final clean = WorkspacePaths.validateName(base);
    final fileName = '$clean.json';
    final rel = '$rootRel/$fileName';
    final abs = paths.resolve(rel);
    if (WorkspacePaths.typeOf(abs) != FileSystemEntityType.notFound) {
      throw const WorkspaceException('A scene with that name already exists');
    }
    final doc = SceneDoc.empty(clean);
    final file = File(abs);
    await file.parent.create(recursive: true);
    await file.writeAsString(doc.encodePretty(), flush: true);
    return fileName;
  }

  String _validatedName(String fileName) {
    final name = fileName.trim();
    if (!name.endsWith('.json')) {
      throw const WorkspaceException('Scene file must end with .json');
    }
    final base = name.substring(0, name.length - 5);
    WorkspacePaths.validateName(base);
    return name;
  }
}
