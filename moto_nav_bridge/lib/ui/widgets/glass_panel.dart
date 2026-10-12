import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

// Inspired by liquid_glass_renderer's glassColor / blur / outlineIntensity
// controls. These tune our existing approximation, not its shader pipeline.
const _glassBlur = 6.0;
const _glassTint = Color(0x1affffff);
const _glassOutlineIntensity = .5;

/// Glass approximation: translucent body with directional bevel highlights.
/// No native refraction or map snapshots; the live backdrop stays interactive.
class GlassPanel extends StatelessWidget {
  const GlassPanel(
      {super.key,
      required this.child,
      this.padding = EdgeInsets.zero,
      this.experimentalLiquid = false});
  final bool experimentalLiquid;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    final base = Theme.of(context);
    const ink = Color(0xff172536);
    final glassTheme = base.copyWith(
      colorScheme: const ColorScheme.light(
        primary: Color(0xff005caf),
        onSurface: ink,
        onSurfaceVariant: Color(0xff35475a),
        outline: Color(0xff536578),
        error: Color(0xffa21b24),
      ),
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      iconTheme: const IconThemeData(color: ink),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: const Color(0xff004f98),
          backgroundColor: const Color(0x3073baff),
          disabledForegroundColor: const Color(0xff536578),
          disabledBackgroundColor: const Color(0x50ffffff),
          side: BorderSide.none,
          shape: const GlassShape(
              borderRadius: BorderRadius.all(Radius.circular(28))),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xff005caf),
          backgroundColor: const Color(0x30ffffff),
          side: BorderSide.none,
          shape: const GlassShape(
              borderRadius: BorderRadius.all(Radius.circular(28))),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
    // Limit the experiment to one iOS card. Unsupported engines and accessible
    // high-contrast mode keep the existing material; no screenshots of MapKit.
    const enabled =
        bool.fromEnvironment('LIQUID_GLASS_TRIAL', defaultValue: false);
    if (experimentalLiquid &&
        enabled &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !highContrast &&
        ImageFilter.isShaderFilterSupported) {
      return LiquidGlass.withOwnLayer(
        settings: const LiquidGlassSettings(
          thickness: 12,
          blur: 4,
          glassColor: Color(0x1affffff),
          lightIntensity: 1.2,
          chromaticAberration: .15,
          saturation: 1.15,
        ),
        shape: const LiquidRoundedSuperellipse(borderRadius: 30),
        glassContainsChild: false,
        child: Theme(
          data: glassTheme,
          child: Material(
              type: MaterialType.transparency,
              child: Padding(padding: padding, child: child)),
        ),
      );
    }
    const radius = BorderRadius.all(Radius.circular(30));
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Color(0x10172536),
            blurRadius: 12,
            // A normal shadow fills the shape behind the translucent panel,
            // tinting its entire backdrop gray. Keep shadow outside only.
            blurStyle: BlurStyle.outer,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          enabled: !highContrast,
          filter: ImageFilter.blur(sigmaX: _glassBlur, sigmaY: _glassBlur),
          child: Container(
            padding: padding,
            decoration: ShapeDecoration(
              shape: highContrast
                  ? const RoundedRectangleBorder(borderRadius: radius)
                  : const GlassShape(),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0, .18, .65, 1],
                colors: highContrast
                    ? const [
                        Color(0xfff4f7fa),
                        Color(0xfff4f7fa),
                        Color(0xfff4f7fa),
                        Color(0xfff4f7fa)
                      ]
                    : const [
                        Color(0x40ffffff),
                        _glassTint,
                        Color(0x24ffffff),
                        Color(0x38ffffff)
                      ],
              ),
            ),
            child: Theme(
              data: glassTheme,
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two inset, directional reflections suggest a curved lip without a white
/// outline. Shared by panel bodies and their controls; never covers content.
class GlassShape extends RoundedRectangleBorder {
  const GlassShape(
      {super.borderRadius = const BorderRadius.all(Radius.circular(30))});

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final radius = borderRadius.resolve(textDirection);
    for (var layer = 0; layer < 2; layer++) {
      final inset = layer == 0 ? .7 : 2.0;
      final path = radius.toRRect(rect).deflate(inset);
      final colors = layer == 0
          ? const [
              Color(0xc0ffffff),
              Color(0x08ffffff),
              Color(0x007499bc),
              Color(0x70ffffff)
            ]
          : const [
              Color(0x00ffffff),
              Color(0x007499bc),
              Color(0x257499bc),
              Color(0x00ffffff)
            ];
      canvas.drawRRect(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = layer == 0 ? .8 : 1.4
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors
                  .map((color) =>
                      color.withValues(alpha: color.a * _glassOutlineIntensity))
                  .toList(),
              stops: const [0, .28, .72, 1],
            ).createShader(rect));
    }
  }
}
