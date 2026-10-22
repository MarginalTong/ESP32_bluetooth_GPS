import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/ui/map_settings_page.dart';

void main() {
  for (final en in [true, false]) {
    testWidgets(
        'map style and traffic persist; saved places are available: $en',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.binding.platformDispatcher.localeTestValue =
          Locale(en ? 'en' : 'zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      await tester.pumpWidget(const MaterialApp(home: MapSettingsPage()));
      await tester.pumpAndSettle();
      expect(find.text(en ? 'SAVED PLACES' : '常用地址'), findsOneWidget);
      await tester.tap(find.text(en ? 'Standard · Dark' : '标准 · 深色'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(MapSettingsPage.styleKey), 'standard_dark');
      await tester.tap(find.text(en ? 'Hybrid' : '混合'));
      await tester.pumpAndSettle();
      final trafficSwitch = find.byType(CupertinoSwitch);
      await tester.tap(trafficSwitch);
      await tester.pumpAndSettle();
      expect(prefs.getString(MapSettingsPage.styleKey), 'hybrid');
      expect(prefs.getBool(MapSettingsPage.trafficKey), isTrue);
      await tester.tap(find.text(en ? 'Satellite' : '卫星'));
      await tester.pumpAndSettle();
      expect(tester.widget<CupertinoSwitch>(trafficSwitch).onChanged, isNull);
      await tester.tap(find.text(en ? 'Hybrid' : '混合'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const MaterialApp(home: MapSettingsPage()));
      await tester.pumpAndSettle();
      expect(tester.widget<CupertinoSwitch>(trafficSwitch).value, isTrue);
    });
  }
}
