import 'package:flutter/widgets.dart';
import '../navio_feedback.dart';

/// An explicit selection event starts the pop, not route/GPS rebuilds. Keeping
/// the same child avoids resetting its state or reconstructing the native map.
class MapSelectionPop extends StatefulWidget {
  const MapSelectionPop({
    super.key,
    required this.selectionRevision,
    required this.child,
    this.enabled = true,
  });
  final int selectionRevision;
  final Widget child;
  final bool enabled;

  @override
  State<MapSelectionPop> createState() => _MapSelectionPopState();
}

class _MapSelectionPopState extends State<MapSelectionPop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale, _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: NavioMotion.mapSelection,
      value: 1,
    );
    _scale = _controller.drive(
      Tween<double>(
        begin: NavioMotion.mapSelectionScale,
        end: 1,
      ).chain(CurveTween(curve: Curves.easeOutBack)),
    );
    _opacity = _controller.drive(
      Tween<double>(
        begin: .35,
        end: 1,
      ).chain(CurveTween(curve: const Interval(0, .3, curve: Curves.easeOut))),
    );
  }

  @override
  void didUpdateWidget(MapSelectionPop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else if (widget.selectionRevision != oldWidget.selectionRevision) {
      _controller.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _controller.value = 1;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _scale,
    alignment: Alignment.bottomCenter,
    child: FadeTransition(opacity: _opacity, child: widget.child),
  );
}
