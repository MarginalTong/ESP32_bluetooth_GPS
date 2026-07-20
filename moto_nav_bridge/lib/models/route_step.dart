import 'device_direction.dart';
import 'lat_lng.dart';

/// A single step of a Google Directions route, already mapped to the device
/// protocol. The [direction] is the maneuver that must be shown as the rider
/// *approaches* [end] (the point where the maneuver happens).
class RouteStep {
  const RouteStep({
    required this.direction,
    required this.start,
    required this.end,
    required this.distanceMeters,
    List<LatLng>? geometry,
    this.rawManeuver,
  }) : geometry = geometry ?? const [];

  final DeviceDirection direction;

  /// Where this step begins (the previous maneuver point).
  final LatLng start;

  /// The maneuver point — where the turn/fork/etc. is performed.
  final LatLng end;

  /// Google's reported length of this step in meters.
  final int distanceMeters;

  /// Full route shape for this step. When unavailable, callers should fall back
  /// to [start] -> [end].
  final List<LatLng> geometry;

  /// The original Google `maneuver` string, kept for debugging/telemetry.
  final String? rawManeuver;

  @override
  String toString() =>
      'RouteStep($direction, ${distanceMeters}m, maneuver=$rawManeuver)';
}
