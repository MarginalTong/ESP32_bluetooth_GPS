import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../config/app_brand.dart';

/// A product silhouette rather than another nested settings card.
class DeviceHeader extends StatelessWidget {
  const DeviceHeader({
    super.key,
    required this.name,
    required this.status,
    required this.connected,
    required this.busy,
    required this.connectLabel,
    this.onConnect,
  });
  final String name, status, connectLabel;
  final bool connected, busy;
  final VoidCallback? onConnect;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
    child: Column(
      children: [
        Container(
          width: 136,
          height: 136,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xff48484a), Color(0xff1c1c1e), Color(0xff080809)],
            ),
            border: Border.all(color: const Color(0xff747478), width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x20000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connected
                      ? CupertinoIcons.location_north_fill
                      : CupertinoIcons.location_north,
                  color: Colors.white,
                  size: 32,
                ),
                const SizedBox(height: 10),
                const Text(
                  AppBrand.name,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2.2,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          name,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -.5,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy) ...[
              const CupertinoActivityIndicator(radius: 7),
              const SizedBox(width: 8),
            ],
            if (connected) ...[
              const Icon(
                CupertinoIcons.checkmark_circle_fill,
                size: 14,
                color: CupertinoColors.systemGreen,
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                status,
                style: TextStyle(
                  fontSize: 15,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ),
          ],
        ),
        if (!connected) ...[
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              onPressed: onConnect,
              borderRadius: BorderRadius.circular(14),
              child: Text(
                connectLabel,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
