import 'package:flutter/cupertino.dart';
import '../../config/app_brand.dart';
import '../navio_theme.dart';
import '../navio_feedback.dart';

/// Presentation only; connection actions and state stay in DeviceHeader.
class DeviceIllustration extends StatelessWidget {
  const DeviceIllustration({super.key, required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: NavioMotion.duration(context, NavioMotion.stateChange),
    width: 136,
    height: 136,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          NavioColors.deviceBodyTop,
          NavioColors.deviceBodyMiddle,
          NavioColors.deviceBodyBottom,
        ],
      ),
      border: Border.all(
        color: connected
            ? CupertinoColors.activeBlue.resolveFrom(context)
            : NavioColors.deviceBezel,
        width: 1.5,
      ),
      boxShadow: [
        BoxShadow(
          color: connected
              ? NavioColors.pairingHalo.withValues(alpha: .22)
              : NavioColors.deviceShadow,
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: Center(child: _symbol(context)),
  );

  Widget _symbol(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      AnimatedSwitcher(
        duration: NavioMotion.duration(context, NavioMotion.stateChange),
        child: Icon(
          key: ValueKey(connected),
          connected
              ? CupertinoIcons.location_north_fill
              : CupertinoIcons.location_north,
          color: CupertinoColors.white,
          size: 32,
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        AppBrand.name,
        style: TextStyle(
          color: CupertinoColors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 2.2,
        ),
      ),
    ],
  );
}
