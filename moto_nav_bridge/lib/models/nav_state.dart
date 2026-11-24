import '../config/ble_constants.dart';
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
    this.speedLimitKph,
    this.rerouting = false,
    this.tripEnded = false,
    this.expiresAtUtcSeconds,
  });

  /// A safe idle/paused state (matches the firmware's STOP icon).
  static const NavState stopped = NavState(
    direction: DeviceDirection.stop,
    distanceMeters: 0,
  );

  /// Shown while a new route is being computed.
  static const recalculating = NavState(
    direction: DeviceDirection.stop,
    distanceMeters: 0,
    rerouting: true,
  );

  /// The signed end-of-trip packet.
  static const NavState ended = NavState(
    direction: DeviceDirection.stop,
    distanceMeters: 0,
    tripEnded: true,
  );

  final DeviceDirection direction;

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
  /// Each group of four integers is one junction arm to draw behind the
  /// main route, nearest first, in the same units as [routePreviewPoints].
  /// The farthest arms are left off the wire when the packet would be too
  /// long for the firmware (see [toWire]).
  final List<int> sideRoadPreviewPoints;

  /// The posted limit where the rider is, in km/h (sent as `L`); null when
  /// the map does not record one, so the display shows no sign.
  final int? speedLimitKph;
  final bool rerouting;

  /// Signed end-of-trip marker; unlike STOP, it returns the display to NAVIO.
  final bool tripEnded;
  // Source-fix deadline, not the time a stalled BLE write was retried.
  final int? expiresAtUtcSeconds;

  Map<String, dynamic> toJson() => {
    'dir': direction.wire,
    'dist': distanceMeters,
    if (expiresAtUtcSeconds != null) 'e': expiresAtUtcSeconds,
    if (speedLimitKph != null) 'L': speedLimitKph,
    if (tripEnded) 'end': true,
    if (rerouting) 'rerouting': true,
    if (routePreviewPoints.isNotEmpty) 'P': routePreviewPoints,
    if (sideRoadPreviewPoints.isNotEmpty) 'R': sideRoadPreviewPoints,
  };

  /// The unsigned JSON body of a navigation write (see `PacketSigner`).
  /// No whitespace: the firmware rejects a write that is too long, so side
  /// roads are dropped, farthest first, until the body fits
  /// [BleConstants.maxNavJsonBytes]. The body is ASCII: one byte a character.
  String toWire() {
    final points = routePreviewPoints;
    final buffer = StringBuffer(
      '{"dir":"${direction.wire}","dist":$distanceMeters',
    );
    if (speedLimitKph != null) buffer.write(',"L":$speedLimitKph');
    if (expiresAtUtcSeconds != null) buffer.write(',"e":$expiresAtUtcSeconds');
    if (tripEnded) buffer.write(',"end":true');
    if (points.isNotEmpty) {
      buffer.write(',"P":[${points.join(',')}]');
    }
    if (rerouting) buffer.write(',"rerouting":true');
    // 1: the closing brace.
    final room = BleConstants.maxNavJsonBytes - buffer.length - 1;
    buffer.write(_sideRoadsWithin(room));
    buffer.write('}');
    return buffer.toString();
  }

  /// `,"R":[...]` with as many whole segments as fit in [room] bytes.
  String _sideRoadsWithin(int room) {
    final roads = sideRoadPreviewPoints;
    for (var count = roads.length ~/ 4 * 4; count >= 4; count -= 4) {
      final text = ',"R":[${roads.take(count).join(',')}]';
      if (text.length <= room) return text;
    }
    return '';
  }

  NavState copyWith({
    DeviceDirection? direction,
    int? distanceMeters,
    List<int>? routePreviewPoints,
    List<int>? sideRoadPreviewPoints,
    int? speedLimitKph,
    bool? rerouting,
    bool? tripEnded,
    int? expiresAtUtcSeconds,
  }) => NavState(
    rerouting: rerouting ?? this.rerouting,
    tripEnded: tripEnded ?? this.tripEnded,
    direction: direction ?? this.direction,
    distanceMeters: distanceMeters ?? this.distanceMeters,
    routePreviewPoints: routePreviewPoints ?? this.routePreviewPoints,
    sideRoadPreviewPoints: sideRoadPreviewPoints ?? this.sideRoadPreviewPoints,
    speedLimitKph: speedLimitKph ?? this.speedLimitKph,
    expiresAtUtcSeconds: expiresAtUtcSeconds ?? this.expiresAtUtcSeconds,
  );

  @override
  bool operator ==(Object other) =>
      other is NavState &&
      other.rerouting == rerouting &&
      other.tripEnded == tripEnded &&
      other.expiresAtUtcSeconds == expiresAtUtcSeconds &&
      other.direction == direction &&
      other.distanceMeters == distanceMeters &&
      other.speedLimitKph == speedLimitKph &&
      _listEquals(other.routePreviewPoints, routePreviewPoints) &&
      _listEquals(other.sideRoadPreviewPoints, sideRoadPreviewPoints);

  @override
  int get hashCode => Object.hash(
    direction,
    rerouting,
    tripEnded,
    expiresAtUtcSeconds,
    distanceMeters,
    speedLimitKph,
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
