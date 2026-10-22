import 'dart:io' show Platform;

import 'package:geolocator/geolocator.dart';

import '../models/lat_lng.dart';
import 'navigation_ports.dart';

/// Thin wrapper around geolocator that yields plain [LatLng]s, keeping the
/// plugin dependency out of the navigation engine and controller logic.
class LocationService implements PositionProvider {
  /// Ensures location services are enabled and permission is granted.
  /// Returns true if we may proceed to stream positions.
  @override
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

  /// One-shot measured position (also refreshes a quiet navigation stream
  /// before voice place search or a confirmed destination change).
  @override
  Future<LatLng> currentPosition() async {
    final p = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    return NavigationFix(p.latitude, p.longitude,
        heading: p.heading,
        accuracy: p.accuracy,
        speed: p.speed,
        timestamp: p.timestamp);
  }

  /// Continuous navigation-grade position stream while riding.
  @override
  Stream<LatLng> positionStream() {
    return Geolocator.getPositionStream(
      locationSettings: _locationSettings,
    ).map((p) => NavigationFix(p.latitude, p.longitude,
        heading: p.heading,
        accuracy: p.accuracy,
        speed: p.speed,
        timestamp: p.timestamp));
  }

  LocationSettings get _locationSettings {
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
      );
    }

    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 5,
    );
  }
}
