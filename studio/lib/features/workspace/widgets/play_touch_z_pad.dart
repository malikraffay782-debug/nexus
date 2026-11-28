import 'package:flutter/material.dart';

/// Compact vertical Z control for play-mode (touch / no keyboard).
///
/// Top half = −Z (Q), bottom half = +Z (E). Release → 0.
/// Kept small for 2 GB landscape: no animation controllers, no allocations
/// beyond a single setState per gesture.
class PlayTouchZPad extends StatefulWidget {
  const PlayTouchZPad({required this.scheme, required this.onSteerZ});

  final ColorScheme scheme;
  final ValueChanged<double> onSteerZ;

  @override
  State<PlayTouchZPad> createState() => _PlayTouchZPadState();
}

class _PlayTouchZPadState extends State<PlayTouchZPad> {
  static const double _w = 44;
  static const double _h = 112;

  /// −1, 0, or +1 while held.
  double _z = 0;

  void _apply(double localY) {
    final mid = _h * 0.5;
    // Dead zone in the middle so resting thumb does not drift Z.
    final dz = localY - mid;
    double next;
    if (dz.abs() < 14) {
      next = 0;
    } else if (dz < 0) {
      next = -1; // top = toward camera (−Z)
    } else {
      next = 1; // bottom = away (+Z)
    }
    if (next == _z) return;
    setState(() => _z = next);
    widget.onSteerZ(next);
  }

  void _clear() {
    if (_z == 0) {
      widget.onSteerZ(0);
      return;
    }
    setState(() => _z = 0);
    widget.onSteerZ(0);
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.scheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final ring = widget.scheme.outline.withValues(alpha: 0.7);
    final active = widget.scheme.primary.withValues(alpha: 0.85);
    final label = widget.scheme.onSurface.withValues(alpha: 0.8);
    return SizedBox(
      width: _w,
      height: _h,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (e) => _apply(e.localPosition.dy),
        onPanUpdate: (e) => _apply(e.localPosition.dy),
        onPanEnd: (_) => _clear(),
        onPanCancel: _clear,
        onTapDown: (e) => _apply(e.localPosition.dy),
        onTapUp: (_) => _clear(),
        onTapCancel: _clear,
        child: CustomPaint(
          painter: _ZPadPainter(
            z: _z,
            bg: bg,
            ring: ring,
            active: active,
            label: label,
          ),
        ),
      ),
    );
  }
}

class _ZPadPainter extends CustomPainter {
  _ZPadPainter({
    required this.z,
    required this.bg,
    required this.ring,
    required this.active,
    required this.label,
  });

  final double z;
  final Color bg;
  final Color ring;
  final Color active;
  final Color label;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(12),
    );
    canvas.drawRRect(r, Paint()..color = bg);
    canvas.drawRRect(
      r,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final mid = size.height * 0.5;
    canvas.drawLine(
      Offset(6, mid),
      Offset(size.width - 6, mid),
      Paint()..color = ring.withValues(alpha: 0.5),
    );
    if (z < 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(2, 2, size.width - 2, mid - 1),
          const Radius.circular(10),
        ),
        Paint()..color = active.withValues(alpha: 0.35),
      );
    } else if (z > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(2, mid + 1, size.width - 2, size.height - 2),
          const Radius.circular(10),
        ),
        Paint()..color = active.withValues(alpha: 0.35),
      );
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    void mark(String s, double y) {
      tp.text = TextSpan(
        text: s,
        style: TextStyle(
          color: label,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      );
      tp.layout();
      tp.paint(canvas, Offset((size.width - tp.width) * 0.5, y));
    }
    mark('−Z', 10);
    mark('+Z', size.height - 22);
  }

  @override
  bool shouldRepaint(covariant _ZPadPainter old) =>
      old.z != z || old.bg != bg || old.active != active;
}
