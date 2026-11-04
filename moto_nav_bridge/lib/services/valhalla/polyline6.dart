import '../../models/lat_lng.dart';

/// Decoder for Valhalla's encoded shape (Google polyline, 6 decimal places).
/// Throws [FormatException] for anything that is not a usable route line.
class Polyline6 {
  const Polyline6._();

  /// Guards memory on a hostile or corrupt response.
  static const maxPoints = 150000;

  static List<LatLng> decode(dynamic value) {
    if (value is! String || value.isEmpty) throw const FormatException();
    final output = <LatLng>[];
    var cursor = 0;
    var latitude = 0;
    var longitude = 0;
    int delta() {
      var result = 0;
      for (var shift = 0; shift <= 30; shift += 5) {
        if (cursor >= value.length) throw const FormatException();
        final byte = value.codeUnitAt(cursor++) - 63;
        if (byte < 0 || byte > 63) throw const FormatException();
        result |= (byte & 31) << shift;
        if (byte < 32) return result.isOdd ? ~(result >> 1) : result >> 1;
      }
      throw const FormatException();
    }

    while (cursor < value.length) {
      if (output.length >= maxPoints) throw const FormatException();
      latitude += delta();
      longitude += delta();
      final point = LatLng(latitude / 1e6, longitude / 1e6);
      if (!isValid(point)) throw const FormatException();
      output.add(point);
    }
    // A line needs two distinct points; a single repeated point is no route.
    if (output.length < 2 ||
        !output.any((point) => output.first.distanceTo(point) > 0.1)) {
      throw const FormatException();
    }
    return output;
  }

  static bool isValid(LatLng point) =>
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude.abs() <= 90 &&
      point.longitude.abs() <= 180;
}
