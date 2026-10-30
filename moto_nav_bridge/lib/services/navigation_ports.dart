import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../models/road_segment.dart';
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

/// Providers without itinerary support must never silently drop required stops.
abstract interface class WaypointRouteProvider implements RouteProvider {
  Future<List<RouteCandidate>> fetchWaypointRoutes({
    required LatLng origin,
    required LatLng destination,
    required List<LatLng> waypoints,
  });
}

abstract interface class SideRoadProvider {
  Future<List<RoadSegment>> fetchSideRoadsNear(LatLng position);
  void dispose();
}

/// Optional rolling, display-only route cache. GPS updates never wait for it.
abstract interface class RouteSideRoadProvider implements SideRoadProvider {
  void prefetchRoute(
    List<LatLng> route,
    LatLng position,
    void Function(LatLng loadedNear) onProgress,
  );
  void advancePrefetch(LatLng position);
  List<RoadSegment> cachedSideRoadsNear(LatLng position);
  int get cacheVersion;
  void cancelPrefetch();
}

abstract interface class PositionProvider {
  Future<bool> ensurePermission();
  Future<LatLng> currentPosition();
  Stream<LatLng> positionStream();
}
