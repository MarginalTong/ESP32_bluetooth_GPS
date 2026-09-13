import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/lat_lng.dart';
import '../../models/route_candidate.dart';

class NavigationMap extends StatefulWidget {
  const NavigationMap({
    super.key,
    this.origin,
    this.destination,
    this.destinationName,
    this.routes = const [],
    this.selectedRouteIndex = 0,
    this.onRouteSelected,
    this.onMapPointSelected,
    this.height = 260,
  });

  static const _viewType = 'moto_nav_bridge/navigation_map';
  static const _events = MethodChannel('moto_nav_bridge/navigation_map_events');
  static const _control =
      MethodChannel('moto_nav_bridge/navigation_map_control');

  final LatLng? origin;
  final LatLng? destination;
  final String? destinationName;
  final List<RouteCandidate> routes;
  final int selectedRouteIndex;
  final ValueChanged<int>? onRouteSelected;
  final ValueChanged<LatLng>? onMapPointSelected;
  final double height;

  @override
  State<NavigationMap> createState() => _NavigationMapState();
}

class _NavigationMapState extends State<NavigationMap> {
  @override
  void initState() {
    super.initState();
    NavigationMap._events.setMethodCallHandler(_handleMapEvent);
  }

  @override
  void didUpdateWidget(covariant NavigationMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_updateKeyFor(widget) != _updateKeyFor(oldWidget)) {
      _sendMapUpdate();
    }
  }

  @override
  void dispose() {
    NavigationMap._events.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _sendMapUpdate() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    await NavigationMap._control
        .invokeMethod<void>('updateMap', _creationParams);
  }

  Future<void> _handleMapEvent(MethodCall call) async {
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    switch (call.method) {
      case 'routeSelected':
        final index = args['index'] as int?;
        if (index == null) return;
        widget.onRouteSelected?.call(index);
      case 'mapPointSelected':
        final latitude = args['latitude'] as double?;
        final longitude = args['longitude'] as double?;
        if (latitude == null || longitude == null) return;
        widget.onMapPointSelected?.call(LatLng(latitude, longitude));
      default:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: SizedBox(
        height: widget.height,
        child: switch (defaultTargetPlatform) {
          TargetPlatform.iOS => UiKitView(
              key: ValueKey(_viewKey),
              viewType: NavigationMap._viewType,
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
    return 'navigation-map';
  }

  String _updateKeyFor(NavigationMap map) {
    final o = map.origin;
    final d = map.destination;
    return [
      o?.latitude.toStringAsFixed(6),
      o?.longitude.toStringAsFixed(6),
      d?.latitude.toStringAsFixed(6),
      d?.longitude.toStringAsFixed(6),
      map.destinationName,
      map.onMapPointSelected != null,
      map.routes.length,
      _routesKeyFor(map.routes),
    ].join(':');
  }

  String _routesKeyFor(List<RouteCandidate> routes) => routes.map((route) {
        final points = route.polyline;
        if (points.isEmpty) return 'empty';
        final first = points.first;
        final last = points.last;
        return [
          route.distanceMeters,
          points.length,
          first.latitude.toStringAsFixed(5),
          first.longitude.toStringAsFixed(5),
          last.latitude.toStringAsFixed(5),
          last.longitude.toStringAsFixed(5),
        ].join(',');
      }).join('|');

  Map<String, Object?> get _creationParams => {
        if (widget.origin != null) ...{
          'originLatitude': widget.origin!.latitude,
          'originLongitude': widget.origin!.longitude,
        },
        if (widget.destination != null) ...{
          'destinationLatitude': widget.destination!.latitude,
          'destinationLongitude': widget.destination!.longitude,
          'destinationName': widget.destinationName,
        },
        'selectedRouteIndex': widget.selectedRouteIndex,
        'mapPointSelectionEnabled': widget.onMapPointSelected != null,
        'routes': [
          for (var i = 0; i < widget.routes.length; i++)
            {
              'index': i,
              'name': widget.routes[i].name,
              'distanceMeters': widget.routes[i].distanceMeters,
              'expectedTravelTimeSeconds':
                  widget.routes[i].expectedTravelTimeSeconds,
              'points': [
                for (final point in widget.routes[i].polyline)
                  {
                    'latitude': point.latitude,
                    'longitude': point.longitude,
                  },
              ],
            },
        ],
      };
}
