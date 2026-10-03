import 'dart:ui';
import 'package:flutter/material.dart';

/// Clipped, static frost: no animated shader or full-screen blur.
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
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: const Color(0xff004f98),
          backgroundColor: const Color(0x2473baff),
          disabledForegroundColor: const Color(0xff536578),
          disabledBackgroundColor: const Color(0x18ffffff),
          side: const BorderSide(color: Color(0x70ffffff)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        enabled: !highContrast,
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withValues(alpha: .28)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: highContrast
                  ? const [Color(0xfff4f7fa), Color(0xfff4f7fa)]
                  : const [Color(0x66ffffff), Color(0x33eef5ff)],
            ),
          ),
          child: Theme(
            data: glassTheme,
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}
