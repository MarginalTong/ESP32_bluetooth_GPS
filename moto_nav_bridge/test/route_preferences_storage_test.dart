import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/controllers/navigation_controller.dart';
import 'navigation_controller_test.dart'
    show FakeBle, FakeRoutes, FakePositions, FakeSideRoads, mainRoute, p0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy locked preferences remain available after upgrade', () async {
    SharedPreferences.setMockInitialValues({
      'route_preferences_test_v1':
          '{"testUnlock":false,"highways":true,"tolls":true,"ferries":false,"tunnels":true}'
    });
    final store = await SharedPreferences.getInstance();
    final positions = FakePositions(current: p0);
    final nav = NavigationController(
        ble: FakeBle(),
        directions: FakeRoutes(mainRoute),
        location: positions,
        sideRoads: FakeSideRoads(),
        preferences: store);
    expect(nav.avoidHighways, isTrue);
    expect(nav.avoidTolls, isTrue);
    expect(nav.avoidTunnels, isTrue);
    nav.dispose();
    await positions.close();
  });
  test('saved settings survive controller recreation', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferences.getInstance();
    final positions = FakePositions(current: p0);
    NavigationController create() => NavigationController(
        ble: FakeBle(),
        directions: FakeRoutes(mainRoute),
        location: positions,
        sideRoads: FakeSideRoads(),
        preferences: store);
    final first = create();
    await first.savePreferences(
        highways: true, tolls: false, ferries: true, tunnels: true);
    first.dispose();
    final restored = create();
    expect(restored.avoidHighways, isTrue);
    expect(restored.avoidTolls, isFalse);
    expect(restored.avoidFerries, isTrue);
    expect(restored.avoidTunnels, isTrue);
    await restored.savePreferences(
        highways: false, tolls: true, ferries: false);
    restored.dispose();
    final changed = create();
    expect(changed.avoidHighways, isFalse);
    expect(changed.avoidTolls, isTrue);
    changed.dispose();
    await positions.close();
  });
}
