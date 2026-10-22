import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/services/nearby_places.dart';

void main() {
  test('brand match, radius and duplicates are enforced', () {
    const origin = LatLng(0, 0);
    final candidates = nearbyCandidates(const [
      PlaceResult(name: 'BP City', address: '', location: LatLng(.001, 0)),
      PlaceResult(
          name: 'bp city duplicate', address: '', location: LatLng(.00101, 0)),
      PlaceResult(name: 'BPA shop', address: '', location: LatLng(.002, 0)),
      PlaceResult(name: 'Shell', address: '', location: LatLng(.003, 0)),
      PlaceResult(name: 'BP far', address: '', location: LatLng(1, 0)),
    ], origin, 'BP');
    expect(candidates.map((e) => e.name), ['BP City']);
  });
  test('no brand substitute when requested brand is missing', () {
    expect(
        nearbyCandidates(const [
          PlaceResult(name: 'Shell', address: '', location: LatLng(0, 0))
        ], const LatLng(0, 0), 'BP'),
        isEmpty);
  });
}
