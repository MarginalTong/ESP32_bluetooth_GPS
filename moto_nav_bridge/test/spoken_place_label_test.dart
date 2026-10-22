import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/services/spoken_place_label.dart';

void main() {
  const location = LatLng(-33.9, 151.1);

  test('speaks venue and suburb without state or postcode', () {
    const place = PlaceResult(
      name: "McDonald's",
      address: '312 Canterbury Rd, Hurlstone Park NSW 2193, Australia',
      location: location,
    );
    expect(spokenPlaceLabel(place), "McDonald's, Hurlstone Park");
  });

  test('does not repeat suburb already in the name', () {
    const place = PlaceResult(
      name: "McDonald's Hurlstone Park",
      address: '312 Canterbury Rd, Hurlstone Park NSW 2193, Australia',
      location: location,
    );
    expect(spokenPlaceLabel(place), "McDonald's Hurlstone Park");
  });

  test('shortens a map result whose name is itself a full address', () {
    const place = PlaceResult(
      name: '312 Canterbury Rd, Hurlstone Park NSW 2193',
      address: '312 Canterbury Rd, Hurlstone Park NSW 2193, Australia',
      location: location,
    );
    expect(spokenPlaceLabel(place), '312 Canterbury Rd, Hurlstone Park');
  });

  test('same-name candidates in one suburb add street for clarity', () {
    const places = [
      PlaceResult(
        name: 'BP',
        address: '12 Canterbury Rd, Hurlstone Park NSW 2193, Australia',
        location: location,
      ),
      PlaceResult(
        name: 'BP',
        address: '5 New Canterbury Rd, Hurlstone Park NSW 2193, Australia',
        location: location,
      ),
    ];
    expect(spokenPlaceOptions(places), [
      'BP, 12 Canterbury Rd, Hurlstone Park',
      'BP, 5 New Canterbury Rd, Hurlstone Park',
    ]);
  });

  test('missing postcode keeps the name without inventing a suburb', () {
    const place = PlaceResult(
      name: 'BP',
      address: 'Canterbury Rd',
      location: location,
    );
    expect(spokenPlaceLabel(place), 'BP');
  });
}
