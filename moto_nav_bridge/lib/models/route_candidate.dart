import 'lat_lng.dart';
import 'route_step.dart';

class RouteCandidate {
  const RouteCandidate({
    required this.steps,
    this.name,
    this.distanceMeters,
    this.expectedTravelTimeSeconds,
  });

  final List<RouteStep> steps;
  final String? name;
  final int? distanceMeters;
  final int? expectedTravelTimeSeconds;

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
}
