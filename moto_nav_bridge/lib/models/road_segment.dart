import 'lat_lng.dart';

class RoadSegment {
  const RoadSegment({
    required this.start,
    required this.end,
  });

  final LatLng start;
  final LatLng end;
}
