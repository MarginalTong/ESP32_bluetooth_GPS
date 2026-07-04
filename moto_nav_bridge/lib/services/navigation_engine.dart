import '../models/device_direction.dart';
import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/route_step.dart';

/// Turns a route + a live position into the [NavState] to show on the device.
///
/// Turn-by-turn model: while traversing step `i` toward its `end`, the rider is
/// told what they will do *at* that end — i.e. the next step's maneuver — with
/// the distance remaining to that point ("in 200 m, turn left"). On the final
/// step the direction is [DeviceDirection.arrived] and the distance counts down
/// to the destination.
///
/// This class is pure Dart (takes plain [LatLng]s), so it is fully unit-testable
/// without the geolocator plugin.
class NavigationEngine {
  NavigationEngine(List<RouteStep> steps)
      : _steps = List.unmodifiable(steps),
        assert(steps.isNotEmpty, 'route must have at least one step');

  final List<RouteStep> _steps;

  int _index = 0;

  /// How close (meters) the rider must get to a maneuver point before we
  /// advance to the next step.
  static const double arrivalThresholdMeters = 15.0;

  int get currentStepIndex => _index;
  int get stepCount => _steps.length;
  bool get isFinished =>
      _index >= _steps.length - 1 &&
      _distanceToStepEnd(_steps.last, _lastKnown) != null &&
      _distanceToStepEnd(_steps.last, _lastKnown)! <= arrivalThresholdMeters;

  LatLng? _lastKnown;

  /// Computes the [NavState] for the given [position], advancing the current
  /// step when the rider reaches (or overshoots) a maneuver point.
  NavState update(LatLng position) {
    _lastKnown = position;
    final n = _steps.length;

    // Advance while the rider has effectively reached the current step's end,
    // or clearly overshot it toward the next one.
    while (_index < n - 1) {
      final current = _steps[_index];
      final distToCurrentEnd = position.distanceTo(current.end);
      final distToNextEnd = position.distanceTo(_steps[_index + 1].end);

      final reached = distToCurrentEnd <= arrivalThresholdMeters;
      final overshot = distToNextEnd < distToCurrentEnd;
      if (reached || overshot) {
        _index++;
      } else {
        break;
      }
    }

    final target = _steps[_index].end;
    final dist = position.distanceTo(target).round();

    // On the last step we are heading to the destination -> ARRIVED.
    // Otherwise show the maneuver performed at the current step's end, which is
    // the next step's mapped direction.
    final DeviceDirection dir = (_index + 1 < n)
        ? _steps[_index + 1].direction
        : DeviceDirection.arrived;

    return NavState(
      direction: dir,
      distanceMeters: dist < 0 ? 0 : dist,
    );
  }

  double? _distanceToStepEnd(RouteStep step, LatLng? from) =>
      from?.distanceTo(step.end);
}
