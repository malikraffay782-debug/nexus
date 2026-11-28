import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'scene_model.dart';
import 'scene_play_state.dart';
import 'scene_project.dart';

/// Play-preview loop for the scene stage (Flutter ticker — not proot).
///
/// Owns time, steer, keyboard focus helpers, Soft/NDC mode, and
/// [ScenePlayState] (real dt integration). UI calls [toggle] / [stop];
/// stage listens to [playTime] for repaints.
class ScenePlayController extends ChangeNotifier {
  ScenePlayController(this._vsync) {
    focusNode.addListener(_onFocusChange);
  }

  final TickerProvider _vsync;

  final ValueNotifier<double> playTime = ValueNotifier(0.0);
  final FocusNode focusNode = FocusNode(debugLabel: 'scenePlay');

  bool _playing = false;
  bool get playing => _playing;

  SceneProjectMode projectMode = SceneProjectMode.soft;

  Offset _steer = Offset.zero;
  Offset get steer => _steer;

  double _steerZ = 0;
  double get steerZ => _steerZ;

  ScenePlayState? _playState;
  ScenePlayState? get playState => _playState;

  final Set<LogicalKeyboardKey> _keys = {};
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;
  bool _disposed = false;

  /// Unit steer from keyboard (WASD / arrows). Touch stick calls [setSteer].
  void setSteer(Offset o) {
    if (_steer == o) return;
    _steer = o;
    notifyListeners();
  }

  void _syncSteerFromKeys() {
    var x = 0.0;
    var y = 0.0;
    var z = 0.0;
    if (_keys.contains(LogicalKeyboardKey.arrowLeft) ||
        _keys.contains(LogicalKeyboardKey.keyA)) {
      x -= 1;
    }
    if (_keys.contains(LogicalKeyboardKey.arrowRight) ||
        _keys.contains(LogicalKeyboardKey.keyD)) {
      x += 1;
    }
    if (_keys.contains(LogicalKeyboardKey.arrowUp) ||
        _keys.contains(LogicalKeyboardKey.keyW)) {
      y -= 1;
    }
    if (_keys.contains(LogicalKeyboardKey.arrowDown) ||
        _keys.contains(LogicalKeyboardKey.keyS)) {
      y += 1;
    }
    // Q = toward camera (−Z in look +Z), E = away (+Z).
    if (_keys.contains(LogicalKeyboardKey.keyQ)) z -= 1;
    if (_keys.contains(LogicalKeyboardKey.keyE)) z += 1;
    setSteer(Offset(x, y));
    if (_steerZ != z) {
      _steerZ = z;
      notifyListeners();
    }
  }

  KeyEventResult onKey(FocusNode node, KeyEvent event) {
    if (!_playing) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final interesting = key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.keyA ||
        key == LogicalKeyboardKey.keyD ||
        key == LogicalKeyboardKey.keyW ||
        key == LogicalKeyboardKey.keyS ||
        key == LogicalKeyboardKey.keyQ ||
        key == LogicalKeyboardKey.keyE;
    if (!interesting) return KeyEventResult.ignored;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _keys.add(key);
      _syncSteerFromKeys();
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _keys.remove(key);
      _syncSteerFromKeys();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Clear stuck keys when focus is lost (KeyUp may never arrive).
  void _onFocusChange() {
    if (focusNode.hasFocus) return;
    if (_keys.isEmpty) return;
    _keys.clear();
    _syncSteerFromKeys();
  }

  void stop({bool notify = true}) {
    _ticker?.dispose();
    _ticker = null;
    final was = _playing;
    _playing = false;
    _steer = Offset.zero;
    _steerZ = 0;
    _keys.clear();
    _playState = null;
    _lastElapsed = Duration.zero;
    if (playTime.value != 0) {
      playTime.value = 0;
    }
    if (notify && was) notifyListeners();
  }

  /// Start or stop. Pass [doc] when starting so runtime state can snapshot.
  /// Returns whether play is active after the call.
  bool toggle([SceneDoc? doc]) {
    if (_playing) {
      stop();
      return false;
    }
    if (doc == null) return false;
    _ticker?.dispose();
    _ticker = null;
    playTime.value = 0;
    _steer = Offset.zero;
    _steerZ = 0;
    _keys.clear();
    _lastElapsed = Duration.zero;
    _playState = ScenePlayState.fromDoc(doc);
    _ticker = _vsync.createTicker((elapsed) {
      if (_disposed || !_playing) return;
      final rawDt =
          (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
      _lastElapsed = elapsed;
      final dt = rawDt.clamp(0.0, ScenePlayState.maxDt);
      _playState?.update(dt, _steer, _steerZ);
      final t = elapsed.inMilliseconds / 1000.0;
      // ~30 fps paint throttle for low-end; state still stepped every tick.
      if ((t - playTime.value).abs() < 1 / 30) return;
      playTime.value = t;
    })
      ..start();
    _playing = true;
    notifyListeners();
    return true;
  }

  void toggleProjectMode() {
    projectMode = projectMode == SceneProjectMode.soft
        ? SceneProjectMode.ndc
        : SceneProjectMode.soft;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    focusNode.removeListener(_onFocusChange);
    stop(notify: false);
    focusNode.dispose();
    playTime.dispose();
    super.dispose();
  }
}
