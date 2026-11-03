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

/// Every fixed color used by NAVIO widgets. Prefer Cupertino dynamic colors;
/// add a named color here only when none fits.
abstract final class NavioColors {
  // Map overlay controls and tab bar over the map.
  static const mapControlDark = Color(0xff121820);
  static const mapControlLight = Color(0xf5ffffff);
  static const mapControlIconLight = Color(0xff3a3a3c);
  static const tabBarLight = Color(0xf5fafafa);
  static const tabActiveOnDark = Color(0xff74b5ff);
  static const tabActiveLight = Color(0xff007aff);
  static const tabInactiveOnDark = Color(0xff8996a8);
  static const tabInactiveLight = Color(0xff8e8e93);
  static const panelDivider = Color(0x33708090);

  // Grouped lists and status.
  static const groupSeparator = Color(0xffdcdce0);
  static const chevron = Color(0xffc7c7cc);
  static const destructive = Color(0xffff3b30);
  static const connected = Color(0xff34c759);
  static const panelDark = Color(0xff1c1c1e);
  static const panelLight = Color(0xfffafafa);

  // Device illustration on My devices.
  static const deviceBodyTop = Color(0xff48484a);
  static const deviceBodyMiddle = Color(0xff1c1c1e);
  static const deviceBodyBottom = Color(0xff080809);
  static const deviceBezel = Color(0xff747478);
  static const deviceShadow = Color(0x20000000);

  // Pairing sheet.
  static const pairingBarrier = Color(0x72000000);
  static const pairingSheetShadow = Color(0x29000000);
  static const pairingHandle = Color(0xffd7dce4);
  static const pairingClose = Color(0xffa8adb7);
  static const pairingAccentText = Color(0xff4465a4);
  static const pairingPhoneIcon = Color(0xff2776d9);
  static const pairingCaption = Color(0xff8c94a1);
  static const pairingHalo = Color(0xff70aeff);
  static const pairingHaloFill = Color(0xffedf5ff);
  static const pairingHaloBorder = Color(0xffd5e8ff);
  static const pairingDisplayFace = Color(0xff1e2735);
  static const pairingDisplayBezel = Color(0xff647285);
  static const pairingDisplayShadow = Color(0x39092c58);

  // Map style preview thumbnails (illustrative, not map data).
  static const previewDarkBase = Color(0xff172536);
  static const previewImageryBase = Color(0xff577963);
  static const previewLightBase = Color(0xffe9ede7);
  static const previewImageryField = Color(0xff749270);
  static const previewImageryWater = Color(0xff385c62);
  static const previewDarkPark = Color(0xff243d43);
  static const previewLightPark = Color(0xffb9d9c3);
  static const previewDarkRoad = Color(0xffa2aeb8);
  static const previewDarkRoute = Color(0xff63aaff);
  static const previewLightRoute = Color(0xffe99836);

  // Google sign-in button: fixed by Google's branding guidelines.
  static const googleFillDark = Color(0xff131314);
  static const googleFillLight = Color(0xffffffff);
  static const googleBorderDark = Color(0xff8e918f);
  static const googleBorderLight = Color(0xff747775);
  static const googleTextDark = Color(0xffe3e3e3);
  static const googleTextLight = Color(0xff1f1f1f);
}
