import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/services/saved_places.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('saved addresses persist and can be independently replaced', () async {
    SharedPreferences.setMockInitialValues({});
    const a = PlaceResult(
        name: 'A', address: 'Address A', location: LatLng(-33, 151));
    const b = PlaceResult(
        name: 'B', address: 'Address B', location: LatLng(-34, 150));
    for (final slot in SavedPlaces.slots) {
      await SavedPlaces().save(slot, a);
    }
    await SavedPlaces().save('home', b);
    final values = await SavedPlaces().load();
    expect(values['home']!.name, 'B');
    expect(values['work']!.name, 'A');
    expect(values['school']!.location.latitude, -33);
  });
  test('corrupt addresses are ignored', () async {
    SharedPreferences.setMockInitialValues({SavedPlaces.key: '{"home":42}'});
    expect(await SavedPlaces().load(), isEmpty);
  });
}
