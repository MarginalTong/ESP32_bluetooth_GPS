import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/route_candidate.dart';
import '../models/route_step.dart';

abstract interface class NavigationBlePort {
  Future<bool> send(NavState state);
  Future<void> disconnect();
}

abstract interface class RouteProvider {
  Future<List<RouteStep>> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  });

  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  });

  void dispose();
}

abstract interface class PositionProvider {
  Future<bool> ensurePermission();
  Future<LatLng> currentPosition();
  Stream<LatLng> positionStream();
}
