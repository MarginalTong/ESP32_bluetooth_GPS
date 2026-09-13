import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/models/lat_lng.dart';
import 'package:moto_nav_bridge/models/place_result.dart';
import 'package:moto_nav_bridge/services/search_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/search_history');
  final service = SearchHistoryService(channel: channel);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'loadSearchHistory') {
        return [
          {
            'name': 'Sydney Opera House',
            'address': 'Bennelong Point',
            'latitude': -33.8568,
            'longitude': 151.2153,
          }
        ];
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('loads place history from the platform channel', () async {
    final history = await service.load();

    expect(history, hasLength(1));
    expect(history.single.name, 'Sydney Opera House');
    expect(history.single.location.latitude, closeTo(-33.8568, 1e-9));
    expect(calls.single.method, 'loadSearchHistory');
  });

  test('saves selected place with compact map payload', () async {
    const place = PlaceResult(
      name: 'Airport',
      address: 'Sydney NSW',
      location: LatLng(-33.9399, 151.1753),
    );

    await service.save(place);

    expect(calls.single.method, 'saveSearchHistory');
    final args = Map<Object?, Object?>.from(calls.single.arguments as Map);
    expect(args['limit'], SearchHistoryService.maxItems);
    expect(args['place'], place.toMap());
  });

  test('clears history through the platform channel', () async {
    await service.clear();

    expect(calls.single.method, 'clearSearchHistory');
  });
}
