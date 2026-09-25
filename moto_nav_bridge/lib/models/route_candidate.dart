import 'lat_lng.dart';
import 'road_segment.dart';
import 'route_step.dart';

class RouteCandidate {
  const RouteCandidate({
    required this.steps,
    this.name,
    this.distanceMeters,
    this.expectedTravelTimeSeconds,
    this.sideRoads = const [],
  });

  final List<RouteStep> steps;
  final String? name;
  final int? distanceMeters;
  final int? expectedTravelTimeSeconds;
  final List<RoadSegment> sideRoads;

  List<LatLng> get polyline {
    final output = <LatLng>[];
    for (final step in steps) {
      final geometry = step.geometry.length >= 2
          ? step.geometry
          : <LatLng>[step.start, step.end];
      for (final point in geometry) {
        if (output.isEmpty || output.last.distanceTo(point) > 0.5) {
          output.add(point);
        }
      }
    }
    return output;
  }

  RouteCandidate copyWith({
    List<RouteStep>? steps,
    String? name,
    int? distanceMeters,
    int? expectedTravelTimeSeconds,
    List<RoadSegment>? sideRoads,
  }) =>
      RouteCandidate(
        steps: steps ?? this.steps,
        name: name ?? this.name,
        distanceMeters: distanceMeters ?? this.distanceMeters,
        expectedTravelTimeSeconds:
            expectedTravelTimeSeconds ?? this.expectedTravelTimeSeconds,
        sideRoads: sideRoads ?? this.sideRoads,
      );
}
