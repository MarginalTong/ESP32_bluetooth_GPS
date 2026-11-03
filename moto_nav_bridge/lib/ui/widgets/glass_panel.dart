import 'dart:ui';
import 'package:flutter/material.dart';
import '../navio_theme.dart';

/// Readable map material. High contrast removes transparency entirely.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final highContrast = MediaQuery.highContrastOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    const radius = BorderRadius.all(Radius.circular(24));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .18 : .08),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          enabled: !highContrast,
          filter: ImageFilter.blur(sigmaX: 4.5, sigmaY: 4.5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: (dark ? NavioColors.panelDark : NavioColors.panelLight)
                  .withValues(alpha: highContrast ? 1 : .91),
              borderRadius: radius,
              border: Border.all(
                color: Colors.white.withValues(alpha: dark ? .10 : .6),
                width: .5,
              ),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
