import 'package:flutter/material.dart';

import '../navio_theme.dart';

/// Round button floating on the map. On a dark map style it uses the dark
/// control color with a white icon.
class MapControlButton extends StatelessWidget {
  const MapControlButton({
    super.key,
    this.backgroundKey,
    required this.dark,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 20,
    this.lightBackground = NavioColors.mapControlLight,
    this.lightIconColor,
    this.minSize,
  });

  final Key? backgroundKey;
  final bool dark;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;
  final Color lightBackground;

  /// Null keeps the theme's icon color on a light map.
  final Color? lightIconColor;

  /// Null keeps IconButton's default touch target.
  final double? minSize;

  @override
  Widget build(BuildContext context) => Material(
    key: backgroundKey,
    color: dark ? NavioColors.mapControlDark : lightBackground,
    shape: const CircleBorder(),
    elevation: 1,
    child: IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(
        icon,
        size: iconSize,
        color: dark ? Colors.white : lightIconColor,
      ),
      constraints: minSize == null
          ? null
          : BoxConstraints(minWidth: minSize!, minHeight: minSize!),
    ),
  );
}
