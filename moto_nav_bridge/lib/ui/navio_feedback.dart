import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import '../services/interaction_haptics.dart';

export '../services/interaction_haptics.dart' show InteractionFeedback;

/// Optional injection for previews/tests; the app uses one throttled driver.
class NavioFeedbackScope extends InheritedWidget {
  const NavioFeedbackScope({
    super.key,
    required this.haptics,
    required super.child,
  });
  final InteractionHaptics haptics;

  @override
  bool updateShouldNotify(NavioFeedbackScope oldWidget) =>
      haptics != oldWidget.haptics;
}

abstract final class NavioFeedback {
  static InteractionHaptics of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<NavioFeedbackScope>()
          ?.haptics ??
      InteractionHaptics.shared;

  static VoidCallback? action(
    BuildContext context,
    VoidCallback? callback, {
    InteractionFeedback feedback = InteractionFeedback.light,
  }) => of(context).action(callback, feedback: feedback);
}

abstract final class NavioMotion {
  static const press = Duration(milliseconds: 90);
  static const release = Duration(milliseconds: 180);
  static const stateChange = Duration(milliseconds: 220);

  static Duration duration(BuildContext context, Duration normal) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : normal;
}

/// Visual feedback only. Listener does not enter the gesture arena, replace
/// button semantics or forward taps. Existing native buttons own activation,
/// keyboard access and scroll cancellation; haptics belong to their callbacks.
class NavioPressEffect extends StatefulWidget {
  const NavioPressEffect({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  State<NavioPressEffect> createState() => _NavioPressEffectState();
}

class _NavioPressEffectState extends State<NavioPressEffect> {
  int? _pointer;
  Offset? _origin;
  bool _pressed = false;

  @override
  void didUpdateWidget(NavioPressEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _pointer = null;
      _origin = null;
      _pressed = false;
    }
  }

  void _down(PointerDownEvent event) {
    if (!widget.enabled || event.buttons != kPrimaryButton) return;
    if (_pointer != null) {
      _release();
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    setState(() => _pressed = true);
  }

  void _release() {
    _pointer = null;
    _origin = null;
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: _down,
      onPointerMove: (event) {
        if (event.pointer == _pointer &&
            _origin != null &&
            (event.position - _origin!).distance > kTouchSlop) {
          _release();
        }
      },
      onPointerUp: (event) {
        if (event.pointer == _pointer) _release();
      },
      onPointerCancel: (event) {
        if (event.pointer == _pointer) _release();
      },
      child: AnimatedScale(
        scale: !reduce && widget.enabled && _pressed ? .97 : 1,
        duration: NavioMotion.duration(
          context,
          _pressed ? NavioMotion.press : NavioMotion.release,
        ),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
