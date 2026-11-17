import 'device_direction.dart';
import 'lane_guidance.dart';
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
    this.roundaboutExitCount,
    this.streetName,
    this.waypointIndex,
    this.lanes,
    this.arrivalSide,
    this.speedLimitsKph,
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

  /// The original provider maneuver identifier (`valhalla:<type>`). Voice
  /// guidance reads the maneuver kind from it; other providers leave it null.
  final String? rawManeuver;

  /// For a roundabout entry, which exit to take, as the provider reported it.
  final int? roundaboutExitCount;

  /// The road this step follows after its maneuver, as the provider named it.
  final String? streetName;

  /// Intermediate stop reached at this segment end, relative to this request.
  final int? waypointIndex;

  /// Lanes to use for the maneuver at [start], when the map marks them.
  final LaneGuidance? lanes;

  /// Which side of the road the stop at [end] is on, when it is known.
  final RoadSide? arrivalSide;

  /// The posted limit on each segment of [geometry] (one entry per pair of
  /// neighbouring points), in km/h; 0 where the map does not record one.
  /// Null when no limits were fetched for this route.
  final List<int>? speedLimitsKph;

  RouteStep copyWith({
    LaneGuidance? lanes,
    RoadSide? arrivalSide,
    List<int>? speedLimitsKph,
  }) => RouteStep(
    direction: direction,
    start: start,
    end: end,
    distanceMeters: distanceMeters,
    geometry: geometry,
    rawManeuver: rawManeuver,
    roundaboutExitCount: roundaboutExitCount,
    streetName: streetName,
    waypointIndex: waypointIndex,
    lanes: lanes ?? this.lanes,
    arrivalSide: arrivalSide ?? this.arrivalSide,
    speedLimitsKph: speedLimitsKph ?? this.speedLimitsKph,
  );

  @override
  String toString() =>
      'RouteStep($direction, ${distanceMeters}m, maneuver=$rawManeuver)';
}
