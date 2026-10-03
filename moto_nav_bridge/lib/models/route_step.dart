import 'device_direction.dart';
import 'lat_lng.dart';

/// A route segment, already mapped to the device protocol. [direction] is the
/// maneuver at [start]. While approaching this segment's [end], the engine
/// announces the next segment's direction; the last end is the destination.
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

  /// The next maneuver point, or the destination for the last segment.
  final LatLng end;

  /// The provider's reported length of this segment in meters.
  final int distanceMeters;

  /// Full route shape for this step. When unavailable, callers should fall back
  /// to [start] -> [end].
  final List<LatLng> geometry;

  /// The original provider maneuver identifier, kept for debugging/telemetry.
  final String? rawManeuver;

  @override
  String toString() =>
      'RouteStep($direction, ${distanceMeters}m, maneuver=$rawManeuver)';
}
