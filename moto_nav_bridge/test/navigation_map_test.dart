import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/device_direction.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/route_candidate.dart';
import 'package:moto_nav_bridge/models/route_step.dart';
import 'package:moto_nav_bridge/ui/widgets/navigation_map.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const control = MethodChannel('moto_nav_bridge/navigation_map_control');
  final updates = <MethodCall>[];

  setUp(() {
    updates.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        SystemChannels.platform_views, (_) async => null);
    messenger.setMockMethodCallHandler(control, (call) async {
      updates.add(call);
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(control, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets(
      'new geometry with identical distance and endpoints reaches native map',
      (tester) async {
    final first = List<RouteCandidate>.unmodifiable([candidate(0.001)]);
    final replacement = List<RouteCandidate>.unmodifiable([candidate(-0.001)]);
    await tester.pumpWidget(map(first));
    await tester.pump();
    await tester.pumpWidget(map(replacement));
    await tester.pump();

    expect(updates, hasLength(1));
    expect(updates.single.method, 'updateMap');
    final route = (updates.single.arguments['routes'] as List).single as Map;
    expect((route['points'] as List)[1]['longitude'], -0.001);
    expect(route['attribution'], '© OpenStreetMap contributors');
    expect(route['attributionUrl'], 'https://www.openstreetmap.org/copyright');

    // Ordinary UI rebuilds with unchanged immutable routes do not resend geometry.
    await tester.pumpWidget(map(replacement));
    await tester.pump();
    expect(updates, hasLength(1));

    await tester.pumpWidget(map(const []));
    await tester.pump();
    expect(updates.last.arguments['routes'], isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}

RouteCandidate candidate(double middleLongitude) => RouteCandidate(
      distanceMeters: 500,
      steps: [
        RouteStep(
          direction: DeviceDirection.up,
          start: const LatLng(0, 0),
          end: const LatLng(0.002, 0),
          distanceMeters: 500,
          geometry: [
            const LatLng(0, 0),
            LatLng(0.001, middleLongitude),
            const LatLng(0.002, 0)
          ],
        )
      ],
      attribution: '© OpenStreetMap contributors',
      attributionUrl: 'https://www.openstreetmap.org/copyright',
    );

Widget map(List<RouteCandidate> routes) => MaterialApp(
        home: Scaffold(
            body: NavigationMap(
      origin: const LatLng(0, 0),
      destination: const LatLng(0.002, 0),
      routes: routes,
    )));
