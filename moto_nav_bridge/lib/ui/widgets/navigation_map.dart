import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_text.dart';
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
    this.routeAnimationId = 0,
    this.mapStyle = 'standard',
    this.showTraffic = false,
    this.onRouteSelected,
    this.onMapPointSelected,
    this.onDiagnostic,
    this.height = 260,
    this.borderRadius = 22,
    this.contentPadding = EdgeInsets.zero,
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

  /// Increment to replay the selected route from origin to destination.
  final int routeAnimationId;
  final String mapStyle;
  final bool showTraffic;
  final ValueChanged<int>? onRouteSelected;
  final ValueChanged<LatLng>? onMapPointSelected;
  final ValueChanged<String>? onDiagnostic;
  final double height;
  final double borderRadius;
  final EdgeInsets contentPadding;

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
    // The controller publishes a new immutable list when a route is replaced.
    // Shape summaries (distance/count/endpoints) can collide for distinct routes,
    // while hashing every coordinate on each GPS update is unnecessary work.
    if (!identical(widget.routes, oldWidget.routes) ||
        _updateKeyFor(widget) != _updateKeyFor(oldWidget)) {
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
      case 'mapDiagnostic':
        final event = args['event'];
        if (event is String) widget.onDiagnostic?.call(event);
        return;
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
    final text = AppText.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
        height: widget.height,
        child: switch (defaultTargetPlatform) {
          TargetPlatform.iOS => UiKitView(
              key: ValueKey(_viewKey),
              viewType: NavigationMap._viewType,
              creationParams: _creationParams,
              creationParamsCodec: const StandardMessageCodec(),
              // Let MapKit's pan, pinch and rotation recognizers own gestures
              // that begin on the map. An eager Flutter recognizer can keep
              // winning subsequent touch sequences in a platform view.
              gestureRecognizers: const {},
            ),
          _ => Container(
              color: colorScheme.surfaceContainer,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(18),
              child: Text(text.iosMapKitOnly),
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
      AppText.system.languageCode,
      map.onMapPointSelected != null,
      map.selectedRouteIndex,
      map.routeAnimationId,
      map.mapStyle,
      map.showTraffic,
      map.contentPadding,
    ].join(':');
  }

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
        'paddingTop': widget.contentPadding.top,
        'paddingBottom': widget.contentPadding.bottom,
        'paddingLeft': widget.contentPadding.left,
        'paddingRight': widget.contentPadding.right,
        'languageCode': AppText.system.languageCode,
        'selectedRouteIndex': widget.selectedRouteIndex,
        'routeAnimationId': widget.routeAnimationId,
        'mapStyle': widget.mapStyle,
        'showTraffic': widget.showTraffic,
        'mapPointSelectionEnabled': widget.onMapPointSelected != null,
        'routes': [
          for (var i = 0; i < widget.routes.length; i++)
            {
              'index': i,
              'name': widget.routes[i].name,
              'distanceMeters': widget.routes[i].distanceMeters,
              'expectedTravelTimeSeconds':
                  widget.routes[i].expectedTravelTimeSeconds,
              'attribution': widget.routes[i].attribution,
              'attributionUrl': widget.routes[i].attributionUrl,
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
