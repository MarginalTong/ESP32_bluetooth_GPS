import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/l10n/app_text.dart';
import 'package:moto_nav_bridge/ui/widgets/language_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => AppText.selected.value = AppLanguage.system);

  Future<void> show(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(
      AppLanguageScope(
        child: const CupertinoApp(
          home: CupertinoPageScaffold(child: LanguageSection()),
        ),
      ),
    );
  }

  Future<void> pick(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('language-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  testWidgets('defaults to the phone language', (tester) async {
    await show(tester);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Follow system'), findsOneWidget);
  });

  testWidgets(
    'choice applies at once, is saved, and can follow the system again',
    (tester) async {
      await show(tester);
      await pick(tester, '简体中文');
      expect(find.text('语言'), findsOneWidget);
      expect(AppText.current.isEnglish, isFalse);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(AppLanguage.storageKey), 'zh');

      await pick(tester, '跟随系统');
      expect(find.text('Language'), findsOneWidget);
      expect(preferences.getString(AppLanguage.storageKey), 'system');
    },
  );

  test('an unknown stored value falls back to the system language', () {
    expect(AppLanguage.fromStorage(null), AppLanguage.system);
    expect(AppLanguage.fromStorage('fr'), AppLanguage.system);
    expect(AppLanguage.fromStorage('en'), AppLanguage.en);
  });
}
