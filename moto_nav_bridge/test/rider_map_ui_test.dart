import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:moto_nav_bridge/controllers/rider_map_controller.dart';
import 'package:moto_nav_bridge/l10n/app_text.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/rider_presence.dart';
import 'package:moto_nav_bridge/ui/widgets/navigation_map.dart';
import 'package:moto_nav_bridge/ui/widgets/rider_map_button.dart';
import 'rider_map_controller_test.dart' show RidersFake;

void main() {
  testWidgets('sharing requires explicit consent; viewing alone never shares', (
    tester,
  ) async {
    final backend = RidersFake();
    final riders = RiderMapController(backend, tick: false);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: riders,
        child: const MaterialApp(
          home: Scaffold(body: RiderMapButton(dark: false)),
        ),
      ),
    );
    final en = AppText.of(
      tester.element(find.byType(RiderMapButton)),
    ).isEnglish;
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(riders.viewing, isTrue);
    expect(riders.sharing, isFalse);
    expect(backend.publishes, 0);
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    expect(riders.sharing, isFalse);
    await tester.tap(find.text(en ? 'Cancel' : '取消'));
    await tester.pumpAndSettle();
    expect(riders.sharing, isFalse);
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(en ? 'Agree and share' : '同意并共享'));
    await tester.pumpAndSettle();
    expect(riders.sharing, isTrue);
    expect(backend.publishes, 0);
    await tester.pumpWidget(const SizedBox());
    riders.dispose();
    await backend.auth.close();
  });

  testWidgets('guests cannot view or publish rider data', (tester) async {
    final backend = RidersFake()..userId = null;
    final riders = RiderMapController(backend, tick: false);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: riders,
        child: const MaterialApp(
          home: Scaffold(body: RiderMapButton(dark: true)),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    for (final tile in tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    )) {
      expect(tile.onChanged, isNull);
    }
    expect(backend.fetches, 0);
    expect(backend.begins, 0);
    await tester.pumpWidget(const SizedBox());
    riders.dispose();
    await backend.auth.close();
  });

  testWidgets(
    'rider movement uses its own channel without refitting route or map',
    (tester) async {
      const control = MethodChannel('moto_nav_bridge/navigation_map_control');
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(control, (call) async {
        calls.add(call);
        return null;
      });
      const id = '10000000-0000-4000-8000-000000000001';
      final expiry = DateTime.now().add(const Duration(seconds: 30));
      Widget map(List<RiderPresence> list) =>
          MaterialApp(home: NavigationMap(riders: list));
      await tester.pumpWidget(
        map([RiderPresence(id, const LatLng(-33.88, 151.12), expiry)]),
      );
      await tester.pump();
      await tester.pumpWidget(
        map([RiderPresence(id, const LatLng(-33.89, 151.12), expiry)]),
      );
      await tester.pump();
      expect(calls.map((c) => c.method), ['updateRiders']);
      final json = (calls.single.arguments as Map)['riders'] as List;
      expect((json.single as Map)['latitude'], -33.89);
      expect(
        (json.single as Map).keys,
        unorderedEquals(['id', 'latitude', 'longitude']),
      );
      await tester.pumpWidget(map(const []));
      await tester.pump();
      expect((calls.last.arguments as Map)['riders'], isEmpty);
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(control, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
