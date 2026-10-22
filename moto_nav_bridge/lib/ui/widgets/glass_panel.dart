import 'dart:ui';

import 'package:flutter/material.dart';

/// Clear map overlay with a restrained lens edge. It does not sample MapKit
/// through a displacement shader, so it cannot render optical refraction.
class GlassPanel extends StatelessWidget {
  const GlassPanel(
      {super.key, required this.child, this.padding = EdgeInsets.zero});
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
    );
    const radius = BorderRadius.all(Radius.circular(30));
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Color(0x17172536),
            blurRadius: 15,
            offset: Offset(0, 5),
            blurStyle: BlurStyle.outer,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          enabled: !highContrast,
          filter: ImageFilter.blur(sigmaX: 4.5, sigmaY: 4.5),
          child: Container(
            padding: padding,
            decoration: ShapeDecoration(
              shape: highContrast
                  ? const RoundedRectangleBorder(borderRadius: radius)
                  : const GlassShape(),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                stops: const [0, .4, 1],
                colors: highContrast
                    ? const [
                        Color(0xfff4f7fa),
                        Color(0xfff4f7fa),
                        Color(0xfff4f7fa)
                      ]
                    : const [
                        Color(0x5effffff),
                        Color(0x48ffffff),
                        Color(0x54ffffff)
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

/// A single directional highlight and a soft opposite edge avoid white frames.
class GlassShape extends RoundedRectangleBorder {
  const GlassShape(
      {super.borderRadius = const BorderRadius.all(Radius.circular(30))});

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final radius = borderRadius.resolve(textDirection);
    for (var layer = 0; layer < 2; layer++) {
      final inset = layer == 0 ? .6 : 2.2;
      final path = radius.toRRect(rect).deflate(inset);
      final colors = switch (layer) {
        0 => const [
            Color(0xb6ffffff),
            Color(0x10ffffff),
            Color(0x00172536),
            Color(0x6affffff),
          ],
        _ => const [
            Color(0x42ffffff),
            Color(0x00ffffff),
            Color(0x24172536),
            Color(0x00ffffff),
          ],
      };
      canvas.drawRRect(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = layer == 0 ? 1.1 : 1.4
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
              stops: const [0, .28, .72, 1],
            ).createShader(rect));
    }
  }
}
