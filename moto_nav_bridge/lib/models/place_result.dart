import 'lat_lng.dart';

class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.address,
    required this.location,
  });

  final String name;
  final String address;
  final LatLng location;

  factory PlaceResult.fromMap(Map<Object?, Object?> map) => PlaceResult(
        name: map['name'] as String? ?? '',
        address: map['address'] as String? ?? '',
        location: LatLng(
          (map['latitude'] as num).toDouble(),
          (map['longitude'] as num).toDouble(),
        ),
      );
}
