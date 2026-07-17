import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/lat_lng.dart';

class NavigationMap extends StatelessWidget {
  const NavigationMap({
    super.key,
    this.origin,
    this.destination,
    this.destinationName,
  });

  static const _viewType = 'moto_nav_bridge/navigation_map';

  final LatLng? origin;
  final LatLng? destination;
  final String? destinationName;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: SizedBox(
        height: 260,
        child: switch (defaultTargetPlatform) {
          TargetPlatform.iOS => UiKitView(
              key: ValueKey(_viewKey),
              viewType: _viewType,
              creationParams: _creationParams,
              creationParamsCodec: const StandardMessageCodec(),
              gestureRecognizers: {
                Factory<OneSequenceGestureRecognizer>(
                  () => EagerGestureRecognizer(),
                ),
              },
            ),
          _ => Container(
              color: colorScheme.surfaceContainer,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(18),
              child: const Text('地图显示目前只接了 iOS MapKit'),
            ),
        },
      ),
    );
  }

  String get _viewKey {
    final o = origin;
    final d = destination;
    return [
      o?.latitude.toStringAsFixed(6),
      o?.longitude.toStringAsFixed(6),
      d?.latitude.toStringAsFixed(6),
      d?.longitude.toStringAsFixed(6),
      destinationName,
    ].join(':');
  }

  Map<String, Object?> get _creationParams => {
        if (origin != null) ...{
          'originLatitude': origin!.latitude,
          'originLongitude': origin!.longitude,
        },
        if (destination != null) ...{
          'destinationLatitude': destination!.latitude,
          'destinationLongitude': destination!.longitude,
          'destinationName': destinationName,
        },
      };
}
