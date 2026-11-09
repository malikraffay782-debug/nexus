import 'dart:convert';
import 'dart:io';

import 'workspace_paths.dart';

class WorkspaceEntry {
  const WorkspaceEntry({
    required this.name,
    required this.relPath,
    required this.isDir,
    required this.depth,
  });

  final String name;
  final String relPath;
  final bool isDir;
  final int depth;
}

class _RawChild {
  _RawChild(this.name, this.isDir);
  final String name;
  final bool isDir;
}

/// Plain dart:io file operations for one project. Every path goes through
/// [WorkspacePaths.resolve], so nothing outside the project can be touched.
class WorkspaceFileService {
  WorkspaceFileService(String projectPath)
      : paths = WorkspacePaths(projectPath);

  final WorkspacePaths paths;

  static const int maxEditableBytes = 1024 * 1024; // 1 MB
  static const int _maxEntries = 2000;
  static const int _maxDepth = 8;

  Future<List<WorkspaceEntry>> listTree() async {
    final out = <WorkspaceEntry>[];
    for (final top in WorkspacePaths.topDirs) {
      final abs = '${paths.root}/$top';
      if (WorkspacePaths.typeOf(abs) != FileSystemEntityType.directory) {
        continue;
      }
      out.add(WorkspaceEntry(name: top, relPath: top, isDir: true, depth: 0));
      await _walk(abs, top, 1, out);
    }
    return out;
  }

  Future<void> _walk(
    String absDir,
    String relDir,
    int depth,
    List<WorkspaceEntry> out,
  ) async {
    if (depth > _maxDepth || out.length >= _maxEntries) return;

    final raw = <_RawChild>[];
    try {
      await for (final e in Directory(absDir).list(followLinks: false)) {
        if (e is Link) continue; // never follow / show symlinks
        // Bound memory while scanning, not only after sort.
        if (raw.length >= _maxEntries) break;
        final name = e.path.substring(e.path.lastIndexOf('/') + 1);
        if (!WorkspacePaths.isValidSegment(name)) continue;
        raw.add(_RawChild(name, e is Directory));
      }
    } on FileSystemException {
      return;
    }

    raw.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    for (final c in raw) {
      if (out.length >= _maxEntries) return;
      final rel = '$relDir/${c.name}';
      out.add(WorkspaceEntry(
        name: c.name,
        relPath: rel,
        isDir: c.isDir,
        depth: depth,
      ));
      if (c.isDir) {
        await _walk('$absDir/${c.name}', rel, depth + 1, out);
      }
    }
  }

  Future<String> readText(String rel) async {
    final abs = paths.resolve(rel);
    if (WorkspacePaths.typeOf(abs) != FileSystemEntityType.file) {
      throw const WorkspaceException('File does not exist');
    }
    final file = File(abs);
    final len = await file.length();
    if (len > maxEditableBytes) {
      throw WorkspaceException(
          'File is too large to edit (${(len / 1024).round()} KB)');
    }
    final bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const WorkspaceException('Not a UTF-8 text file');
    }
  }

  /// Writes via temp file + rename so a crash never leaves a half-written file.
  Future<void> writeText(String rel, String content) async {
    final abs = paths.resolve(rel);
    if (WorkspacePaths.typeOf(abs) != FileSystemEntityType.file) {
      throw const WorkspaceException('File no longer exists');
    }
    final tmpPath = '$abs.nexus_tmp';
    try {
      if (WorkspacePaths.typeOf(tmpPath) != FileSystemEntityType.notFound) {
        await File(tmpPath).delete();
      }
      final tmp = File(tmpPath);
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(abs);
    } on FileSystemException catch (e) {
      try {
        final tmp = File(tmpPath);
        if (tmp.existsSync()) await tmp.delete();
      } catch (_) {}
      throw WorkspaceException('Save failed: ${e.message}');
    }
  }

  /// Creates an empty file in [parentRel]. Returns its relative path.
  Future<String> createFile(String parentRel, String name) async {
    final rel = await _childRel(parentRel, name);
    final abs = paths.resolve(rel);
    try {
      await File(abs).create(exclusive: true);
    } on FileSystemException catch (e) {
      throw WorkspaceException('Could not create file: ${e.message}');
    }
    return rel;
  }

  Future<String> createFolder(String parentRel, String name) async {
    final rel = await _childRel(parentRel, name);
    final abs = paths.resolve(rel);
    try {
      await Directory(abs).create();
    } on FileSystemException catch (e) {
      throw WorkspaceException('Could not create folder: ${e.message}');
    }
    return rel;
  }

  Future<String> _childRel(String parentRel, String name) async {
    final clean = WorkspacePaths.validateName(name);
    final parentAbs = paths.resolve(parentRel);
    if (WorkspacePaths.typeOf(parentAbs) != FileSystemEntityType.directory) {
      throw const WorkspaceException('Parent folder does not exist');
    }
    final rel = '$parentRel/$clean';
    final abs = paths.resolve(rel);
    if (WorkspacePaths.typeOf(abs) != FileSystemEntityType.notFound) {
      throw const WorkspaceException('A file or folder with that name exists');
    }
    return rel;
  }

  Future<void> deleteFile(String rel) async {
    final normalized = rel.trim();
    // Entry point required by native ProjectMount / Run.
    if (normalized == 'src/main.py') {
      throw const WorkspaceException(
        'Cannot delete src/main.py — it is the project entry script',
      );
    }
    final abs = paths.resolve(rel);
    if (WorkspacePaths.typeOf(abs) != FileSystemEntityType.file) {
      throw const WorkspaceException('Only files can be deleted');
    }
    try {
      await File(abs).delete();
    } on FileSystemException catch (e) {
      throw WorkspaceException('Delete failed: ${e.message}');
    }
  }

  /// Deletes an empty folder only. Non-empty folders are refused (safe default).
  Future<void> deleteFolder(String rel) async {
    final abs = paths.resolve(rel);
    if (WorkspacePaths.typeOf(abs) != FileSystemEntityType.directory) {
      throw const WorkspaceException('Not a folder');
    }
    // Never delete top-level project dirs (src/assets/scenes/screens)
    final parts = rel.split('/');
    if (parts.length == 1 && WorkspacePaths.topDirs.contains(parts.first)) {
      throw const WorkspaceException('Cannot delete top-level project folders');
    }
    final dir = Directory(abs);
    try {
      await for (final _ in dir.list(followLinks: false)) {
        throw const WorkspaceException(
          'Folder is not empty. Delete files inside first.',
        );
      }
      await dir.delete();
    } on WorkspaceException {
      rethrow;
    } on FileSystemException catch (e) {
      throw WorkspaceException('Delete folder failed: ${e.message}');
    }
  }
}
