import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/services/apple_maps_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('nearby search supplies origin and category to MapKit', () async {
    const channel = MethodChannel('moto_nav_bridge/apple_maps');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'searchPlaces');
      expect(call.arguments['latitude'], -33.0);
      expect(call.arguments['longitude'], 151.0);
      expect(call.arguments['category'], 'fuel');
      expect(call.arguments['query'], 'BP petrol station');
      return <Object>[];
    });
    expect(
        await AppleMapsService().search('BP petrol station',
            near: const LatLng(-33, 151), category: 'fuel'),
        isEmpty);
  });
}
