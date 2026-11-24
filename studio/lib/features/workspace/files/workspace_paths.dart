import 'dart:io';

import 'package:path/path.dart' as p;

/// User-facing error for any workspace file problem (bad path, too large, ...).
class WorkspaceException implements Exception {
  const WorkspaceException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Resolves project-relative paths (always '/'-separated) to absolute paths,
/// guaranteeing the result stays inside the project and under one of the
/// allowed top-level folders **or** a controlled root-level file.
/// Rejects '..', absolute paths, empty segments, odd characters and symlinks.
class WorkspacePaths {
  WorkspacePaths(String projectPath) : root = _canonicalRoot(projectPath);

  final String root;

  /// Allowed top-level folders. Extend deliberately; never open the project root
  /// for arbitrary listing or write.
  static const List<String> topDirs = [
    'src',
    'assets',
    'scenes',
    'screens',
    'notes',
  ];

  /// Controlled single-segment files allowed at the project root (not folders).
  /// Keep this list short and explicit.
  static const List<String> rootFiles = [
    'README.md',
    'NOTES.md',
  ];

  static const int maxNameLength = 100;
  /// Must stay in sync with [WorkspaceFileService] walk depth.
  static const int maxDepth = 8;
  static final RegExp _badChars = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

  static String _trimTrailingSlashes(String s) {
    var r = s;
    while (r.length > 1 && r.endsWith('/')) {
      r = r.substring(0, r.length - 1);
    }
    return r;
  }

  /// Prefer the real path so symlink roots cannot slip past later segment checks.
  static String _canonicalRoot(String projectPath) {
    final trimmed = _trimTrailingSlashes(projectPath);
    try {
      return Directory(trimmed).resolveSymbolicLinksSync();
    } on FileSystemException {
      return trimmed;
    }
  }

  /// Validates a single file/folder name. Returns the trimmed name.
  static String validateName(String raw) {
    final name = raw.trim();
    if (name.isEmpty) {
      throw const WorkspaceException('Name is empty');
    }
    if (name.length > maxNameLength) {
      throw const WorkspaceException('Name is too long');
    }
    if (name == '.' || name.contains('..')) {
      throw const WorkspaceException('Name cannot contain ".."');
    }
    if (name.startsWith('.')) {
      throw const WorkspaceException('Name cannot start with "."');
    }
    if (_badChars.hasMatch(name)) {
      throw const WorkspaceException('Name has invalid characters');
    }
    return name;
  }

  static bool isValidSegment(String s) {
    try {
      return validateName(s) == s;
    } on WorkspaceException {
      return false;
    }
  }

  static bool isRootFile(String name) => rootFiles.contains(name);

  /// Turns "src/main.py" or "NOTES.md" into an absolute path after validating.
  String resolve(String relPath) {
    final rel = relPath.trim();
    if (rel.isEmpty || rel.startsWith('/')) {
      throw const WorkspaceException('Invalid path');
    }
    if (rel.endsWith('/')) {
      throw const WorkspaceException('Invalid path');
    }
    final parts = rel.split('/');
    if (parts.any((s) => s.isEmpty)) {
      throw const WorkspaceException('Invalid path');
    }
    // Nested depth under a top dir: parts[0]=top, parts[1..] nest → max parts = maxDepth+1
    if (parts.length > maxDepth + 1) {
      throw const WorkspaceException('Path is too deep');
    }
    for (final s in parts) {
      if (!isValidSegment(s)) {
        throw WorkspaceException('Invalid path segment "$s"');
      }
    }

    final isControlledRoot =
        parts.length == 1 && rootFiles.contains(parts.first);
    if (!isControlledRoot && !topDirs.contains(parts.first)) {
      throw const WorkspaceException(
        'Files must live in src, assets, scenes, screens, notes, '
        'or be README.md / NOTES.md at project root',
      );
    }

    if (_isLink(root)) {
      throw const WorkspaceException('Project folder is a symlink');
    }
    var current = root;
    for (final s in parts) {
      current = '$current/$s';
      if (_isLink(current)) {
        throw const WorkspaceException('Symlinks are not allowed');
      }
    }
    // Final containment: resolved path must stay under the canonical project root.
    if (!p.equals(root, current) && !p.isWithin(root, current)) {
      throw const WorkspaceException('Resolved path escaped project root');
    }
    return current;
  }

  static bool _isLink(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link;

  static FileSystemEntityType typeOf(String absPath) =>
      FileSystemEntity.typeSync(absPath, followLinks: false);
}
