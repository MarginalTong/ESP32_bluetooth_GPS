import 'package:geolocator/geolocator.dart';

import '../models/lat_lng.dart';

/// Thin wrapper around geolocator that yields plain [LatLng]s, keeping the
/// plugin dependency out of the navigation engine and controller logic.
class LocationService {
  /// Ensures location services are enabled and permission is granted.
  /// Returns true if we may proceed to stream positions.
  Future<bool> ensurePermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// One-shot current position (used to seed the route origin).
  Future<LatLng> currentPosition() async {
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LatLng(p.latitude, p.longitude);
  }

  /// Continuous position stream while riding. Emits on ~5 m of movement.
  Stream<LatLng> positionStream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      ),
    ).map((p) => LatLng(p.latitude, p.longitude));
  }
}
