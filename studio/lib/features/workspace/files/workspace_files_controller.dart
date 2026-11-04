import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'code_text_controller.dart';
import 'workspace_file_service.dart';
import 'workspace_paths.dart';

class FileActionResult {
  const FileActionResult({this.error, this.relPath});
  final String? error;
  final String? relPath;
  bool get ok => error == null;
}

/// State for the file tree + code editor of one open project.
class WorkspaceFilesController extends ChangeNotifier {
  WorkspaceFilesController(String projectPath)
      : service = WorkspaceFileService(projectPath) {
    text.addListener(_onTextChanged);
  }

  final WorkspaceFileService service;
  final CodeTextController text = CodeTextController();

  List<WorkspaceEntry> _entries = const [];
  final Set<String> _collapsed = <String>{};
  bool _loadingTree = false;
  String? _treeError;

  String? _openPath;
  String _savedText = '';
  bool _dirty = false;
  bool _opening = false;
  bool _saving = false;
  bool _disposed = false;
  int _openGen = 0;

  bool get loadingTree => _loadingTree;
  String? get treeError => _treeError;
  String? get openPath => _openPath;
  bool get dirty => _dirty;
  bool get opening => _opening;
  bool get saving => _saving;

  bool isCollapsed(String relPath) => _collapsed.contains(relPath);

  List<WorkspaceEntry> get visibleEntries {
    if (_collapsed.isEmpty) return _entries;
    return _entries
        .where((e) => !_collapsed.any((c) => e.relPath.startsWith('$c/')))
        .toList();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onTextChanged() {
    if (_openPath == null) return;
    final d = text.text != _savedText;
    if (d != _dirty) {
      _dirty = d;
      _notify();
    }
  }

  void toggleCollapsed(String relPath) {
    if (!_collapsed.remove(relPath)) _collapsed.add(relPath);
    _notify();
  }

  Future<void> refreshTree() async {
    _loadingTree = true;
    _treeError = null;
    _notify();
    try {
      final list = await service.listTree();
      if (_disposed) return;
      _entries = list;
    } on WorkspaceException catch (e) {
      _treeError = e.message;
    } catch (e) {
      _treeError = 'Could not read project files';
    } finally {
      _loadingTree = false;
      _notify();
    }
  }

  /// Opens a file in the editor. Returns an error message, or null on success.
  /// Callers must confirm discarding unsaved changes before calling this.
  Future<String?> openFile(String relPath) async {
    final gen = ++_openGen;
    _opening = true;
    _notify();
    try {
      final content = await service.readText(relPath);
      if (_disposed || gen != _openGen) return null;
      _savedText = content;
      _openPath = relPath;
      text.highlightPython = relPath.endsWith('.py');
      text.value = TextEditingValue(text: content);
      _dirty = false;
      return null;
    } on WorkspaceException catch (e) {
      if (gen != _openGen) return null;
      return e.message;
    } catch (_) {
      if (gen != _openGen) return null;
      return 'Could not open file';
    } finally {
      if (gen == _openGen) {
        _opening = false;
        _notify();
      }
    }
  }

  /// Saves the open file. Returns an error message, or null on success.
  Future<String?> save() async {
    final path = _openPath;
    if (path == null || _saving) return null;
    _saving = true;
    _notify();
    final snapshot = text.text;
    final savedForPath = path;
    try {
      await service.writeText(path, snapshot);
      if (_disposed) return null;
      if (_openPath != savedForPath) return null;
      _savedText = snapshot;
      _dirty = text.text != _savedText;
      return null;
    } on WorkspaceException catch (e) {
      return e.message;
    } catch (_) {
      return 'Save failed';
    } finally {
      _saving = false;
      _notify();
    }
  }

  void closeFile() {
    _openPath = null;
    _savedText = '';
    _dirty = false;
    text.highlightPython = false;
    text.value = TextEditingValue.empty;
    _notify();
  }

  Future<FileActionResult> createFile(String parentRel, String name) async {
    try {
      final rel = await service.createFile(parentRel, name);
      await refreshTree();
      return FileActionResult(relPath: rel);
    } on WorkspaceException catch (e) {
      return FileActionResult(error: e.message);
    } catch (_) {
      return const FileActionResult(error: 'Could not create file');
    }
  }

  Future<FileActionResult> createFolder(String parentRel, String name) async {
    try {
      final rel = await service.createFolder(parentRel, name);
      _collapsed.remove(parentRel);
      await refreshTree();
      return FileActionResult(relPath: rel);
    } on WorkspaceException catch (e) {
      return FileActionResult(error: e.message);
    } catch (_) {
      return const FileActionResult(error: 'Could not create folder');
    }
  }

  Future<String?> deleteFile(String relPath) async {
    try {
      await service.deleteFile(relPath);
      if (relPath == _openPath) closeFile();
      await refreshTree();
      return null;
    } on WorkspaceException catch (e) {
      return e.message;
    } catch (_) {
      return 'Delete failed';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    text.removeListener(_onTextChanged);
    text.dispose();
    super.dispose();
  }
}
