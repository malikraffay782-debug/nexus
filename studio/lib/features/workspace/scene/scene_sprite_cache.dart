import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'scene_model.dart';

/// Decodes and caches sprite files under the project root.
///
/// Hard caps for 2 GB phones: max file bytes, max edge, max entries.
/// Rejects paths that [SceneSprites.normalize] does not accept.
class SceneSpriteCache extends ChangeNotifier {
  SceneSpriteCache(this.projectRoot);

  final String projectRoot;

  static const int maxBytes = 256 * 1024; // 256 KB
  static const int maxEdge = 512;
  static const int maxEntries = 8;

  final Map<String, ui.Image> _images = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};
  int _epoch = 0;

  /// Bumps when an image finishes loading — painters can compare.
  int get epoch => _epoch;

  ui.Image? get(String? raw) {
    final key = SceneSprites.normalize(raw);
    if (key.isEmpty) return null;
    return _images[key];
  }

  bool failed(String? raw) {
    final key = SceneSprites.normalize(raw);
    return key.isNotEmpty && _failed.contains(key);
  }

  /// Kick off decode if needed. Safe to call every frame.
  void prefer(String? raw) {
    final key = SceneSprites.normalize(raw);
    if (key.isEmpty) return;
    if (_images.containsKey(key) || _failed.contains(key) || _loading.contains(key)) {
      return;
    }
    _loading.add(key);
    _load(key);
  }

  Future<void> _load(String key) async {
    try {
      final file = File('$projectRoot/$key');
      if (!await file.exists()) {
        _failed.add(key);
        return;
      }
      final len = await file.length();
      if (len <= 0 || len > maxBytes) {
        _failed.add(key);
        return;
      }
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: maxEdge,
        targetHeight: maxEdge,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      // Evict oldest if over cap (insertion order via keys).
      while (_images.length >= maxEntries) {
        final first = _images.keys.first;
        _images.remove(first)?.dispose();
      }
      _images[key] = image;
      _epoch++;
      notifyListeners();
    } catch (_) {
      _failed.add(key);
    } finally {
      _loading.remove(key);
    }
  }

  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _loading.clear();
    _failed.clear();
    _epoch++;
    notifyListeners();
  }

  @override
  void dispose() {
    clear();
    super.dispose();
  }
}
