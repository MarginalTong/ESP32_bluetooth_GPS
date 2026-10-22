import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/services/saved_places.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/ui/widgets/saved_places_bar.dart';

void main() {
  for (final en in [true, false]) {
    testWidgets('saved place shortcuts select persisted coordinates: $en',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.binding.platformDispatcher.localeTestValue =
          Locale(en ? 'en' : 'zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      const home = PlaceResult(
          name: 'Saved home',
          address: 'My address',
          location: LatLng(-33, 151));
      await SavedPlaces().save('home', home);
      PlaceResult? selected;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: 320,
                  child: SavedPlacesBar(onSelected: (p) => selected = p)))));
      await tester.pumpAndSettle();
      expect(find.text(en ? 'Home' : '家'), findsOneWidget);
      expect(find.text(en ? 'Work' : '公司'), findsOneWidget);
      expect(find.text(en ? 'School' : '学校'), findsOneWidget);
      expect(find.text(en ? 'Edit' : '修改'), findsNWidgets(3));
      await tester.tap(find.text(en ? 'Home' : '家'));
      expect(selected!.location.latitude, -33);
      expect(tester.takeException(), isNull);
    });
  }
}
