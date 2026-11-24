import 'package:flutter/material.dart';

/// Compact virtual stick for play-mode Player steer (touch / low-end).
///
/// Outputs a unit-ish [Offset] in stage axes (x right, y down). Releases to zero.
class PlayTouchStick extends StatefulWidget {
  const PlayTouchStick({required this.scheme, required this.onSteer});

  final ColorScheme scheme;
  final ValueChanged<Offset> onSteer;

  @override
  State<PlayTouchStick> createState() => PlayTouchStickState();
}

class PlayTouchStickState extends State<PlayTouchStick> {
  static const double _size = 112;
  static const double _knob = 44;
  static const double _max = (_size - _knob) * 0.5;

  Offset _delta = Offset.zero;

  void _setDelta(Offset local) {
    final center = const Offset(_size / 2, _size / 2);
    var d = local - center;
    final m = d.distance;
    if (m > _max && m > 1e-6) {
      d = d * (_max / m);
    }
    if ((d - _delta).distanceSquared < 0.25) return;
    setState(() => _delta = d);
    final nx = (d.dx / _max).clamp(-1.0, 1.0);
    final ny = (d.dy / _max).clamp(-1.0, 1.0);
    widget.onSteer(Offset(nx, ny));
  }

  void _clear() {
    if (_delta == Offset.zero) {
      widget.onSteer(Offset.zero);
      return;
    }
    setState(() => _delta = Offset.zero);
    widget.onSteer(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.scheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final ring = widget.scheme.outline.withValues(alpha: 0.7);
    final knob = widget.scheme.primary.withValues(alpha: 0.9);
    return SizedBox(
      width: _size,
      height: _size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (e) => _setDelta(e.localPosition),
        onPanUpdate: (e) => _setDelta(e.localPosition),
        onPanEnd: (_) => _clear(),
        onPanCancel: _clear,
        child: CustomPaint(
          painter: _StickPainter(
            delta: _delta,
            bg: bg,
            ring: ring,
            knob: knob,
            knobR: _knob / 2,
          ),
        ),
      ),
    );
  }
}

class _StickPainter extends CustomPainter {
  _StickPainter({
    required this.delta,
    required this.bg,
    required this.ring,
    required this.knob,
    required this.knobR,
  });

  final Offset delta;
  final Color bg;
  final Color ring;
  final Color knob;
  final double knobR;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = bg);
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(c + delta, knobR, Paint()..color = knob);
  }

  @override
  bool shouldRepaint(covariant _StickPainter old) =>
      old.delta != delta || old.bg != bg || old.knob != knob;
}
