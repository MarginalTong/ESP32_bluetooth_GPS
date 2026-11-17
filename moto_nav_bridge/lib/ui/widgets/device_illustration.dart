import 'package:flutter/cupertino.dart';
import '../../config/app_brand.dart';
import '../navio_theme.dart';

/// Presentation only; connection actions and state stay in DeviceHeader.
class DeviceIllustration extends StatelessWidget {
  const DeviceIllustration({super.key, required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) => Container(
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
      border: Border.all(color: NavioColors.deviceBezel, width: 1.5),
      boxShadow: const [
        BoxShadow(
          color: NavioColors.deviceShadow,
          blurRadius: 24,
          offset: Offset(0, 10),
        ),
      ],
    ),
    child: Center(child: _symbol()),
  );

  Widget _symbol() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        connected
            ? CupertinoIcons.location_north_fill
            : CupertinoIcons.location_north,
        color: CupertinoColors.white,
        size: 32,
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
