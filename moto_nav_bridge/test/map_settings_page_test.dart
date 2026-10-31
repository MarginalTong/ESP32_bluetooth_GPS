import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/ui/map_settings_page.dart';

void main() {
  for (final en in [true, false]) {
    testWidgets(
        'map style persists, traffic is gone, saved places are available: $en',
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
      expect(prefs.getString(MapSettingsPage.styleKey), 'hybrid');
      expect(find.byType(CupertinoSwitch), findsNothing);
      expect(find.text(en ? 'Show traffic' : '显示交通状况'), findsNothing);
    });
  }
}
