import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/services/navigation_ports.dart';
import 'package:moto_nav_bridge/services/valhalla_directions_service.dart';
import 'navigation_controller_test.dart'
    show FakeBle, FakePositions, FakeSideRoads;
import 'waypoint_routes_test.dart' show leg;

const origin = LatLng(0, 0),
    first = LatLng(.001, 0),
    second = LatLng(.002, 0),
    destination = LatLng(.003, 0);
const stops = [
  PlaceResult(name: 'First', address: '', location: first),
  PlaceResult(name: 'Second', address: '', location: second),
];

class ItineraryProvider implements WaypointRouteProvider {
  final requests = <List<LatLng>>[];
  Completer<List<RouteCandidate>>? pending;
  @override
  Future<List<RouteCandidate>> fetchWaypointRoutes({
    required LatLng origin,
    required LatLng destination,
    required List<LatLng> waypoints,
  }) async {
    requests.add(List.of(waypoints));
    if (pending != null) return pending!.future;
    final points = [origin, ...waypoints, destination];
    return ValhallaDirectionsService.parseRoutesJson(
      jsonEncode({
        'trip': {
          'status': 0,
          'units': 'kilometers',
          'summary': {'length': .333, 'time': 50},
          'legs': [
            for (var i = 0; i + 1 < points.length; i++)
              leg(points[i], points[i + 1]),
          ],
        },
      }),
      expectedLegs: points.length - 1,
    );
  }

  @override
  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
  }) => fetchWaypointRoutes(
    origin: origin,
    destination: destination,
    waypoints: const [],
  );
  @override
  Future<List<RouteStep>> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  }) async =>
      (await fetchRoutes(origin: origin, destination: destination)).first.steps;
  @override
  void dispose() {}
}

void main() {
  late ItineraryProvider routes;
  late FakePositions positions;
  late NavigationController nav;
  setUp(() {
    routes = ItineraryProvider();
    positions = FakePositions(current: origin);
    nav = NavigationController(
      ble: FakeBle(),
      directions: routes,
      location: positions,
      sideRoads: FakeSideRoads(),
    );
  });
  tearDown(() async {
    nav.dispose();
    await positions.close();
  });

  test('preview and Start retain ordered stops, stop clears them', () async {
    await nav.previewDestination(destination, waypoints: stops);
    expect(nav.waypoints, stops);
    await nav.startNavigation(destination);
    expect(routes.requests, [
      [first, second],
      [first, second],
    ]);
    expect(nav.phase, NavPhase.navigating);
    positions.emit(first);
    await pumpEventQueue();
    expect(nav.completedWaypoints, 1);
    expect(nav.phase, NavPhase.navigating);
    positions.emit(second);
    await pumpEventQueue();
    expect(nav.completedWaypoints, 2);
    expect(nav.phase, NavPhase.navigating);
    positions.emit(destination);
    await pumpEventQueue();
    expect(nav.phase, NavPhase.arrived);
    await nav.stopNavigation();
    expect(nav.waypoints, isEmpty);
  });

  test('reroute retains only unvisited stops and renumbers progress', () async {
    await nav.startNavigation(destination, waypoints: stops);
    positions.emit(first);
    await pumpEventQueue();
    expect(nav.completedWaypoints, 1);
    const off = LatLng(.0012, .002);
    positions.emit(off);
    positions.emit(off);
    await pumpEventQueue(times: 40);
    expect(routes.requests.last, [second]);
    expect(routes.requests.length, 2);
    positions.emit(second);
    await pumpEventQueue();
    expect(nav.completedWaypoints, 2);
  });

  test('starting at the first stop avoids a zero-length leg', () async {
    positions.current = first;
    await nav.startNavigation(destination, waypoints: stops);
    expect(nav.completedWaypoints, 1);
    expect(routes.requests.single, [second]);
    expect(nav.phase, NavPhase.navigating);
  });

  test('late preview cannot overwrite a newer itinerary', () async {
    routes.pending = Completer();
    final slow = nav.previewDestination(destination, waypoints: stops);
    await pumpEventQueue();
    final pending = routes.pending!;
    routes.pending = null;
    await nav.previewDestination(destination, waypoints: [stops.last]);
    final newest = nav.selectedRoute;
    pending.complete(
      await routes.fetchWaypointRoutes(
        origin: origin,
        destination: destination,
        waypoints: [first, second],
      ),
    );
    await slow;
    expect(nav.waypoints, [stops.last]);
    expect(nav.selectedRoute, same(newest));
  });

  test(
    'a jump to the final destination cannot bypass unvisited stops',
    () async {
      await nav.startNavigation(destination, waypoints: stops);
      positions.emit(destination);
      await pumpEventQueue();
      expect(nav.phase, NavPhase.navigating);
      expect(nav.completedWaypoints, 0);
      positions.emit(destination);
      await pumpEventQueue(times: 40);
      expect(routes.requests.last, [first, second]);
      expect(nav.phase, NavPhase.navigating);
    },
  );

  test(
    'preview failure clears stale geometry instead of showing old itinerary',
    () async {
      await nav.previewDestination(destination, waypoints: stops);
      routes.pending = Completer();
      final loading = nav.previewDestination(
        destination,
        waypoints: [stops.last],
      );
      await pumpEventQueue();
      routes.pending!.completeError(Exception('failed'));
      await loading;
      expect(nav.selectedRoute, isNull);
      expect(nav.previewingRoute, isFalse);
      expect(nav.error, isNotNull);
    },
  );
}
