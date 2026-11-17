import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// The user's Connect-button specification. Diameter, not radius, is 2.4w.
abstract final class TapRippleStyle {
  static const duration = Duration(milliseconds: 450);
  static const diameterFactor = 2.4;
  static const initialOpacity = .28;
}

class TapRipple extends StatefulWidget {
  const TapRipple({
    super.key,
    required this.child,
    this.enabled = true,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });
  final Widget child;
  final bool enabled;
  final BorderRadius borderRadius;

  @override
  State<TapRipple> createState() => _TapRippleState();
}

class _TapRippleState extends State<TapRipple>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  @override
  void initState() {
    super.initState();
    _animation =
        AnimationController(vsync: this, duration: TapRippleStyle.duration)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted) {
              setState(() => _origin = null);
            }
          });
  }

  Offset? _origin, _downPosition;
  int? _pointer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _cancel();
  }

  void _down(PointerDownEvent event) {
    if (!widget.enabled ||
        MediaQuery.disableAnimationsOf(context) ||
        event.buttons != kPrimaryButton) {
      return;
    }
    if (_pointer != null) {
      _cancel();
      return;
    }
    _pointer = event.pointer;
    _downPosition = event.position;
    setState(() => _origin = event.localPosition);
    _animation.forward(from: 0);
  }

  void _cancel() {
    _animation.stop();
    _pointer = null;
    _downPosition = null;
    if (_origin != null && mounted) setState(() => _origin = null);
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: (event) {
      if (event.pointer == _pointer &&
          _downPosition != null &&
          (event.position - _downPosition!).distance > kTouchSlop) {
        _cancel();
      }
    },
    onPointerCancel: (event) {
      if (event.pointer == _pointer) _cancel();
    },
    onPointerUp: (event) {
      if (event.pointer == _pointer) {
        _pointer = null;
        _downPosition = null;
      }
    },
    child: Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (_origin != null && !MediaQuery.disableAnimationsOf(context))
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: TapRipplePainter(
                    origin: _origin!,
                    progress: _animation,
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: widget.borderRadius,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Repaints only the overlay, never the underlying map or button layout.
class TapRipplePainter extends CustomPainter {
  TapRipplePainter({
    required this.origin,
    required this.progress,
    required this.color,
    required this.borderRadius,
  }) : super(repaint: progress);
  final Offset origin;
  final Animation<double> progress;
  final Color color;
  final BorderRadius borderRadius;

  double radiusFor(double width) =>
      width *
      TapRippleStyle.diameterFactor /
      2 *
      Curves.easeOutCubic.transform(progress.value.clamp(0.0, 1.0));
  double get opacity =>
      TapRippleStyle.initialOpacity * (1 - progress.value.clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRRect(borderRadius.toRRect(Offset.zero & size));
    canvas.drawCircle(
      origin,
      radiusFor(size.width),
      Paint()..color = color.withValues(alpha: opacity),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(TapRipplePainter oldDelegate) =>
      origin != oldDelegate.origin ||
      color != oldDelegate.color ||
      progress != oldDelegate.progress ||
      borderRadius != oldDelegate.borderRadius;
}
