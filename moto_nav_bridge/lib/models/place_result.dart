import 'lat_lng.dart';

class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.address,
    required this.location,
    this.sourceUrl,
    this.resolutionStatus,
  });

  final String name;
  final String address;
  final LatLng location;
  final String? sourceUrl;
  final String? resolutionStatus;

  Map<String, Object> toMap() => {
        'name': name,
        'address': address,
        'latitude': location.latitude,
        'longitude': location.longitude,
        if (sourceUrl != null) 'sourceUrl': sourceUrl!,
        if (resolutionStatus != null) 'resolutionStatus': resolutionStatus!,
      };

  factory PlaceResult.fromMap(Map<Object?, Object?> map) => PlaceResult(
        name: map['name'] as String? ?? '',
        address: map['address'] as String? ?? '',
        sourceUrl: map['sourceUrl'] as String?,
        resolutionStatus: map['resolutionStatus'] as String?,
        location: LatLng(
          (map['latitude'] as num).toDouble(),
          (map['longitude'] as num).toDouble(),
        ),
      );
}
