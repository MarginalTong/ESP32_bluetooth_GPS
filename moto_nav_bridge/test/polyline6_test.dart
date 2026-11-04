import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/valhalla/polyline6.dart';

import 'valhalla_directions_service_test.dart' show encode;

void main() {
  final rejects = throwsA(isA<FormatException>());

  test('decodes six-decimal coordinates, including negative ones', () {
    const line = [LatLng(-33.868820, 151.209296), LatLng(-33.815000, 151.001)];
    final decoded = Polyline6.decode(encode(line));
    expect(decoded, hasLength(2));
    expect(decoded.first.latitude, closeTo(-33.86882, 1e-9));
    expect(decoded.last.longitude, closeTo(151.001, 1e-9));
  });

  test('rejects a missing, truncated or out-of-alphabet shape', () {
    final valid = encode(const [LatLng(0, 0), LatLng(0.001, 0)]);
    expect(() => Polyline6.decode(null), rejects);
    expect(() => Polyline6.decode(''), rejects);
    expect(
      () => Polyline6.decode(valid.substring(0, valid.length - 1)),
      rejects,
    );
    expect(() => Polyline6.decode('$valid '), rejects);
  });

  test('rejects a single point or a line that never moves', () {
    expect(() => Polyline6.decode(encode(const [LatLng(1, 1)])), rejects);
    expect(
      () => Polyline6.decode(encode(const [LatLng(1, 1), LatLng(1, 1)])),
      rejects,
    );
  });

  test('rejects coordinates outside the globe', () {
    expect(
      () => Polyline6.decode(encode(const [LatLng(0, 0), LatLng(91, 0)])),
      rejects,
    );
    expect(Polyline6.isValid(const LatLng(90, -180)), isTrue);
    expect(Polyline6.isValid(const LatLng(double.nan, 0)), isFalse);
  });
}
