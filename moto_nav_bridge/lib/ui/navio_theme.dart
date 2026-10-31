import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Shared iOS-style foundations. Map appearance is independent of app theme.
abstract final class NavioTheme {
  static ThemeData light() => _theme(Brightness.light);
  static ThemeData dark() => _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final ink = dark ? const Color(0xfff5f5f7) : const Color(0xff1c1c1e);
    final secondary = dark ? const Color(0xff98989f) : const Color(0xff636366);
    final surface = dark ? const Color(0xff1c1c1e) : Colors.white;
    final blue = dark ? const Color(0xff0a84ff) : const Color(0xff007aff);
    final base = ThemeData(
      brightness: brightness,
      platform: TargetPlatform.iOS,
      fontFamily: '.SF Pro Text',
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: blue, brightness: brightness)
          .copyWith(
            primary: blue,
            onPrimary: Colors.white,
            surface: surface,
            onSurface: ink,
            onSurfaceVariant: secondary,
            error: dark ? const Color(0xffff453a) : const Color(0xffff3b30),
          ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: dark ? Colors.black : const Color(0xfff2f2f7),
      cupertinoOverrideTheme: CupertinoThemeData(
        brightness: brightness,
        primaryColor: blue,
        scaffoldBackgroundColor: dark ? Colors.black : const Color(0xfff2f2f7),
        barBackgroundColor: dark
            ? const Color(0xf01c1c1e)
            : const Color(0xf7f2f2f7),
      ),
      textTheme: base.textTheme
          .copyWith(
            headlineLarge: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: -.8,
              color: ink,
            ),
            headlineMedium: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -.6,
              color: ink,
            ),
            titleLarge: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -.4,
              color: ink,
            ),
            titleMedium: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -.3,
              color: ink,
            ),
            titleSmall: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: ink,
            ),
            bodyLarge: TextStyle(fontSize: 17, letterSpacing: -.3, color: ink),
            bodyMedium: TextStyle(fontSize: 15, letterSpacing: -.2, color: ink),
            bodySmall: TextStyle(fontSize: 13, color: secondary),
            labelLarge: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -.3,
            ),
            labelMedium: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: secondary,
            ),
          )
          .apply(fontFamily: '.SF Pro Text'),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? Colors.black : const Color(0xfff2f2f7),
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: '.SF Pro Text',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xff2c2c2e) : const Color(0xffe9e9ee),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: blue,
          foregroundColor: Colors.white,
          minimumSize: const Size(44, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontFamily: '.SF Pro Text',
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          textStyle: const TextStyle(
            fontFamily: '.SF Pro Text',
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: dark ? const Color(0xff38383a) : const Color(0xffdedee3),
        thickness: .5,
        space: 1,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// Pushed Cupertino pages need a body style; CupertinoPageScaffold alone does
/// not replace MaterialApp's red/yellow debug fallback text style.
class NavioPage extends StatelessWidget {
  const NavioPage({
    super.key,
    this.navigationBar,
    this.backgroundColor,
    required this.child,
  });
  final ObstructingPreferredSizeWidget? navigationBar;
  final Color? backgroundColor;
  final Widget child;

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
      inherit: false,
      color: CupertinoColors.label.resolveFrom(context),
      decoration: TextDecoration.none,
    ),
    child: CupertinoPageScaffold(
      navigationBar: navigationBar,
      backgroundColor:
          backgroundColor ??
          CupertinoColors.systemGroupedBackground.resolveFrom(context),
      child: child,
    ),
  );
}

class SettingsIcon extends StatelessWidget {
  const SettingsIcon(
    this.icon, {
    super.key,
    this.color = CupertinoColors.systemBlue,
  });
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 30,
    height: 30,
    decoration: BoxDecoration(
      color: CupertinoDynamicColor.resolve(color, context),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Icon(icon, size: 19, color: Colors.white),
  );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key});
  final String label;
  @override
  Widget build(BuildContext context) => Text(
    label,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      letterSpacing: .1,
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
    ),
  );
}
