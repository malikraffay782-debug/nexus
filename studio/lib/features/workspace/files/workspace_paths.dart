import 'dart:io';

/// User-facing error for any workspace file problem (bad path, too large, ...).
class WorkspaceException implements Exception {
  const WorkspaceException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Resolves project-relative paths (always '/'-separated) to absolute paths,
/// guaranteeing the result stays inside the project and under one of the
/// allowed top-level folders. Rejects '..', absolute paths, odd characters
/// and symlinks.
class WorkspacePaths {
  WorkspacePaths(String projectPath) : root = _trimTrailingSlashes(projectPath);

  final String root;

  static const List<String> topDirs = ['src', 'assets', 'scenes', 'screens'];
  static const int maxNameLength = 100;
  static final RegExp _badChars = RegExp(r'[\\/:*?"<>|\x00-\x1f]');

  static String _trimTrailingSlashes(String s) {
    var r = s;
    while (r.length > 1 && r.endsWith('/')) {
      r = r.substring(0, r.length - 1);
    }
    return r;
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

  /// Turns "src/main.py" into "<root>/src/main.py" after validating it.
  String resolve(String relPath) {
    final rel = relPath.trim();
    if (rel.isEmpty || rel.startsWith('/')) {
      throw const WorkspaceException('Invalid path');
    }
    final parts = rel.split('/');
    for (final s in parts) {
      if (!isValidSegment(s)) {
        throw WorkspaceException('Invalid path segment "$s"');
      }
    }
    if (!topDirs.contains(parts.first)) {
      throw const WorkspaceException(
          'Files must live in src, assets, scenes or screens');
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
    return current;
  }

  static bool _isLink(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link;

  static FileSystemEntityType typeOf(String absPath) =>
      FileSystemEntity.typeSync(absPath, followLinks: false);
}
