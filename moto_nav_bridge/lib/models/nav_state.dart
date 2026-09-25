import 'device_direction.dart';

/// The navigation payload sent to the ESP32 over BLE.
///
/// Serializes to exactly `{"dir":"LEFT","dist":200}` — the contract the
/// firmware parses with `doc["dir"]` / `doc["dist"]`. The firmware reads
/// `dist` as an `int`, so [distanceMeters] is emitted without a fractional
/// part. Keep the payload small: the firmware buffer is `StaticJsonDocument<768>`.
class NavState {
  const NavState({
    required this.direction,
    required this.distanceMeters,
    this.routePreviewPoints = const [],
    this.sideRoadPreviewPoints = const [],
  });

  final DeviceDirection direction;

  /// Distance to the next maneuver, in whole meters. Never negative.
  final int distanceMeters;

  /// Flattened OLED mini-map points: `[x0,y0,x1,y1,...]`.
  ///
  /// These are screen coordinates for the ESP32 display, not latitude/longitude.
  /// Keep this small so the BLE payload stays reliable.
  final List<int> routePreviewPoints;

  /// Flattened mini-map side-road segments: `[x0,y0,x1,y1,...]`.
  ///
  /// Each group of four integers is one nearby real road segment to draw
  /// behind the main route.
  final List<int> sideRoadPreviewPoints;

  /// A safe idle/paused state (matches the firmware's STOP icon).
  static const NavState stopped =
      NavState(direction: DeviceDirection.stop, distanceMeters: 0);

  Map<String, dynamic> toJson() => {
        'dir': direction.wire,
        'dist': distanceMeters,
        if (routePreviewPoints.isNotEmpty) 'p': routePreviewPoints,
        if (sideRoadPreviewPoints.isNotEmpty) 'r': sideRoadPreviewPoints,
      };

  /// The exact bytes written to the BLE characteristic.
  /// Uses no whitespace to stay well under the firmware's 200-byte buffer.
  String toWire() {
    final points = routePreviewPoints;
    final roads = sideRoadPreviewPoints;
    final buffer = StringBuffer(
      '{"dir":"${direction.wire}","dist":$distanceMeters',
    );
    if (points.isNotEmpty) {
      buffer.write(',"p":[${points.join(',')}]');
    }
    if (roads.isNotEmpty) {
      buffer.write(',"r":[${roads.join(',')}]');
    }
    buffer.write('}');
    return buffer.toString();
  }

  NavState copyWith({
    DeviceDirection? direction,
    int? distanceMeters,
    List<int>? routePreviewPoints,
    List<int>? sideRoadPreviewPoints,
  }) =>
      NavState(
        direction: direction ?? this.direction,
        distanceMeters: distanceMeters ?? this.distanceMeters,
        routePreviewPoints: routePreviewPoints ?? this.routePreviewPoints,
        sideRoadPreviewPoints:
            sideRoadPreviewPoints ?? this.sideRoadPreviewPoints,
      );

  @override
  bool operator ==(Object other) =>
      other is NavState &&
      other.direction == direction &&
      other.distanceMeters == distanceMeters &&
      _listEquals(other.routePreviewPoints, routePreviewPoints) &&
      _listEquals(other.sideRoadPreviewPoints, sideRoadPreviewPoints);

  @override
  int get hashCode => Object.hash(
        direction,
        distanceMeters,
        Object.hashAll(routePreviewPoints),
        Object.hashAll(sideRoadPreviewPoints),
      );

  @override
  String toString() => 'NavState($direction, ${distanceMeters}m)';
}

bool _listEquals(List<int> a, List<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
