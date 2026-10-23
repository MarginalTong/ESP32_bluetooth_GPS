import 'device_direction.dart';

/// The navigation payload sent to the ESP32 over BLE.
///
/// Serializes to compact JSON such as
/// `{"dir":"LEFT","dist":200,"P":[...],"R":[...]}`; `PacketSigner` then adds
/// the counter and signature before it is written. The firmware reads `dist`
/// as an `int`, so [distanceMeters] is emitted without a fractional part.
class NavState {
  const NavState({
    required this.direction,
    required this.distanceMeters,
    this.routePreviewPoints = const [],
    this.sideRoadPreviewPoints = const [],
    this.rerouting = false,
  });

  final DeviceDirection direction;
  final bool rerouting;
  static const recalculating = NavState(
      direction: DeviceDirection.stop, distanceMeters: 0, rerouting: true);

  /// Distance to the next maneuver, in whole meters. Never negative.
  final int distanceMeters;

  /// Flattened mini-map points: `[x0,y0,x1,y1,...]`, in tenths of a unit of
  /// the 128x64 mini-map (sent as `P`; older firmware read whole units as `p`).
  ///
  /// These are screen coordinates for the ESP32 display, not latitude/longitude.
  /// Keep this small so the BLE payload stays reliable.
  final List<int> routePreviewPoints;

  /// Flattened mini-map side-road segments: `[x0,y0,x1,y1,...]`.
  ///
  /// Each group of four integers is one nearby real road segment to draw
  /// behind the main route, in the same units as [routePreviewPoints].
  final List<int> sideRoadPreviewPoints;

  /// A safe idle/paused state (matches the firmware's STOP icon).
  static const NavState stopped =
      NavState(direction: DeviceDirection.stop, distanceMeters: 0);

  Map<String, dynamic> toJson() => {
        'dir': direction.wire,
        'dist': distanceMeters,
        if (rerouting) 'rerouting': true,
        if (routePreviewPoints.isNotEmpty) 'P': routePreviewPoints,
        if (sideRoadPreviewPoints.isNotEmpty) 'R': sideRoadPreviewPoints,
      };

  /// The unsigned JSON body of a navigation write (see `PacketSigner`).
  /// No whitespace: the firmware rejects writes over 400 bytes, signature
  /// included.
  String toWire() {
    final points = routePreviewPoints;
    final roads = sideRoadPreviewPoints;
    final buffer = StringBuffer(
      '{"dir":"${direction.wire}","dist":$distanceMeters',
    );
    if (points.isNotEmpty) {
      buffer.write(',"P":[${points.join(',')}]');
    }
    if (rerouting) buffer.write(',"rerouting":true');
    if (roads.isNotEmpty) {
      buffer.write(',"R":[${roads.join(',')}]');
    }
    buffer.write('}');
    return buffer.toString();
  }

  NavState copyWith({
    DeviceDirection? direction,
    int? distanceMeters,
    List<int>? routePreviewPoints,
    List<int>? sideRoadPreviewPoints,
    bool? rerouting,
  }) =>
      NavState(
        rerouting: rerouting ?? this.rerouting,
        direction: direction ?? this.direction,
        distanceMeters: distanceMeters ?? this.distanceMeters,
        routePreviewPoints: routePreviewPoints ?? this.routePreviewPoints,
        sideRoadPreviewPoints:
            sideRoadPreviewPoints ?? this.sideRoadPreviewPoints,
      );

  @override
  bool operator ==(Object other) =>
      other is NavState &&
      other.rerouting == rerouting &&
      other.direction == direction &&
      other.distanceMeters == distanceMeters &&
      _listEquals(other.routePreviewPoints, routePreviewPoints) &&
      _listEquals(other.sideRoadPreviewPoints, sideRoadPreviewPoints);

  @override
  int get hashCode => Object.hash(
        direction,
        rerouting,
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
