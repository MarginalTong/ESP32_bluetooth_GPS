import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/navio_theme.dart';

void main() {
  test('native themes have readable primary buttons and consistent type', () {
    for (final theme in [NavioTheme.light(), NavioTheme.dark()]) {
      expect(theme.colorScheme.primary.a, 1);
      expect(theme.textTheme.bodyLarge!.fontSize, 17);
      expect(theme.textTheme.titleMedium!.fontWeight, FontWeight.w600);
      expect(theme.platform, TargetPlatform.iOS);
    }
  });

  testWidgets('pushed native pages have normal adaptive body text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NavioTheme.light(),
        darkTheme: NavioTheme.dark(),
        themeMode: ThemeMode.dark,
        home: const NavioPage(child: Text('Account details')),
      ),
    );
    final context = tester.element(find.text('Account details'));
    final style = DefaultTextStyle.of(context).style;
    expect(style.decoration, TextDecoration.none);
    expect(style.fontSize, 17);
    expect(style.color!.toARGB32(), CupertinoColors.label.darkColor.toARGB32());
    expect(tester.takeException(), isNull);
  });
}
