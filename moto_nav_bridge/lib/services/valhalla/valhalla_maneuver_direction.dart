import 'dart:math' as math;

import '../../models/device_direction.dart';
import '../../models/lat_lng.dart';
import '../../models/route_step.dart';

/// Maps Valhalla maneuver types to the display's arrows.
/// Types: https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/
class ValhallaManeuverDirection {
  const ValhallaManeuverDirection._();

  /// The arrow for maneuver [type] on the step `shape[begin..end]`. Throws
  /// [FormatException] for transit, stairs and unknown types rather than
  /// disguising them as straight on.
  static DeviceDirection of(int type, List<LatLng> shape, int begin, int end) {
    switch (type) {
      case 0 || 1 || 2 || 3 || 7 || 8 || 17 || 22 || 28 || 29:
        return DeviceDirection.up;
      case 9 || 18 || 20 || 23 || 37:
        return DeviceDirection.bearRight;
      case 10 || 11:
        return DeviceDirection.right;
      case 12 || 13:
        return DeviceDirection.uturn;
      case 14 || 15:
        return DeviceDirection.left;
      case 16 || 19 || 21 || 24 || 38:
        return DeviceDirection.bearLeft;
      case 25 || 26 || 27:
        // Firmware has no roundabout/merge glyph. For entry use the net turn
        // from the approach to the exit, not the first curved ring segment.
        // Keep both real maneuvers/geometry; never invent an exit number.
        return _geometric(shape, begin, type == 26 ? end : begin);
      default:
        throw const FormatException();
    }
  }

  /// The Valhalla turn type for a new leg's start, which the provider reports
  /// as a plain START/CONTINUE although the rider may be turning at the stop.
  static int joinType(RouteStep previous, List<LatLng> outgoing) {
    final incoming = previous.geometry;
    // 2 m: skip duplicate or near-duplicate points at the junction.
    final before = incoming.reversed.firstWhere(
      (p) => p.distanceTo(previous.end) >= 2,
      orElse: () => previous.start,
    );
    final after = outgoing.firstWhere(
      (p) => p.distanceTo(outgoing.first) >= 2,
      orElse: () => outgoing.last,
    );
    final turn = _signedTurn(
      bearing(before, previous.end),
      bearing(outgoing.first, after),
    );
    // Degrees; the bands match Valhalla's own slight/regular/U-turn types.
    if (turn.abs() < 20) return 1;
    if (turn.abs() >= 160) return 12;
    if (turn > 0) return turn < 50 ? 9 : 10;
    return turn > -50 ? 16 : 15;
  }

  static DeviceDirection _geometric(List<LatLng> shape, int entry, int exit) {
    var before = entry - 1;
    var after = exit + 1;
    // 1 m: skip repeated points so the tangent is a real direction.
    while (before >= 0 && shape[before].distanceTo(shape[entry]) < 1) {
      before--;
    }
    while (after < shape.length && shape[exit].distanceTo(shape[after]) < 1) {
      after++;
    }
    // Starting inside a junction has no incoming tangent to infer a turn.
    if (before < 0 || after >= shape.length) return DeviceDirection.up;
    final angle = _signedTurn(
      bearing(shape[before], shape[entry]),
      bearing(shape[exit], shape[after]),
    );
    // Degrees: wider bands than [joinType] because ring geometry is curved.
    if (angle.abs() >= 165) return DeviceDirection.uturn;
    if (angle.abs() < 25) return DeviceDirection.up;
    if (angle.abs() < 60) {
      return angle > 0 ? DeviceDirection.bearRight : DeviceDirection.bearLeft;
    }
    return angle > 0 ? DeviceDirection.right : DeviceDirection.left;
  }

  /// Compass bearing a -> b in degrees, on a local flat frame.
  static double bearing(LatLng a, LatLng b) =>
      math.atan2(
        (b.longitude - a.longitude) * math.cos(a.latitude * math.pi / 180),
        b.latitude - a.latitude,
      ) *
      180 /
      math.pi;

  /// Turn from [incoming] to [outgoing] in (-180, 180]; positive is right.
  static double _signedTurn(double incoming, double outgoing) =>
      (outgoing - incoming + 540) % 360 - 180;
}
