import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moto_nav_bridge/config/account_config.dart';
import 'package:moto_nav_bridge/models/account_data.dart';
import 'package:moto_nav_bridge/services/local_account_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const place = {
    'slot': 'home',
    'name': 'Synthetic home',
    'address': 'Address',
    'latitude': -33.0,
    'longitude': 151.0
  };
  Map<String, Object> data({int revision = 1}) => {
        'revision': revision,
        'display_name': 'Rider',
        'preferences': {'map_style': 'hybrid', 'avoid_tolls': true},
        'places': [place]
      };

  test(
      'cloud payload is an allowlist, excluding BLE keys and place source metadata',
      () {
    final parsed = AccountData.fromCloud({
      ...data(),
      'signing_key': 'never',
      'history': [1, 2]
    });
    final text = jsonEncode(parsed.toCloud());
    expect(text, isNot(contains('signing_key')));
    expect(text, isNot(contains('history')));
    expect(text, isNot(contains('sourceUrl')));
    expect(parsed.places['home']!.location.latitude, -33);
  });
  test('rejects malformed cloud records before applying any local data', () {
    for (final invalid in [
      {...data(), 'revision': -1},
      {
        ...data(),
        'preferences': {'map_style': 'unknown'}
      },
      {
        ...data(),
        'preferences': {'avoid_tolls': 'true'}
      },
      {
        ...data(),
        'places': [
          {...place, 'latitude': double.nan}
        ]
      },
      {
        ...data(),
        'places': [
          {...place, 'longitude': 181}
        ]
      },
      {
        ...data(),
        'places': [place, place]
      },
      {
        ...data(),
        'places': [
          {...place, 'slot': 'other'}
        ]
      },
    ]) {
      expect(() => AccountData.fromCloud(invalid), throwsFormatException);
    }
  });
  test(
      'public keys are accepted; admin keys, insecure endpoints and embedded passwords are rejected',
      () {
    expect(
        const AccountConfig(
                url: 'https://example.supabase.co',
                publishableKey: 'sb_publishable_12345678901234567890')
            .configured,
        isTrue);
    for (final url in [
      'http://example.test',
      'https://user:password@example.test',
      'https://example.test/?key=x'
    ]) {
      expect(
          AccountConfig(
                  url: url,
                  publishableKey: 'sb_publishable_12345678901234567890')
              .configured,
          isFalse);
    }
    final payload = base64Url.encode(utf8.encode('{"role":"service_role"}'));
    for (final key in ['sb_secret_12345', 'a.$payload.b', '']) {
      expect(
          AccountConfig(url: 'https://example.test', publishableKey: key)
              .configured,
          isFalse);
    }
  });
  test('account switching isolates each account and restores guest data',
      () async {
    SharedPreferences.setMockInitialValues({
      'saved_places_v1': jsonEncode({
        'home': {...place}
      }),
      'nav_display_binding_v2': 'local-ble-key',
      'unrelated': 'keep'
    });
    final prefs = await SharedPreferences.getInstance();
    final store = LocalAccountData(prefs);
    await store.activate('user-a');
    expect(store.activeId, 'user-a');
    expect(store.capture().places, isEmpty);
    await store.replace(AccountData.fromCloud(data()));
    await store.activate('user-b');
    expect(store.capture().places, isEmpty);
    await store.activate('user-a');
    expect(store.capture().places['home']!.name, 'Synthetic home');
    await store.activate(null);
    expect(store.activeId, isNull);
    expect(store.capture().places['home']!.name, 'Synthetic home');
    expect(prefs.getString('nav_display_binding_v2'), 'local-ble-key');
    expect(prefs.getString('unrelated'), 'keep');
  });
  test('account deletion removes only the previous account cache', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalAccountData(prefs);
    await store.activate('user-a');
    await store.replace(AccountData.fromCloud(data()));
    await store.activate(null, erasePrevious: true);
    expect(prefs.containsKey('navio.account.data.user-a'), isFalse);
    expect(store.activeId, isNull);
    expect(store.capture().places, isEmpty);
  });
  test(
      'unfinished profile switches recover from a persisted journal on restart',
      () async {
    SharedPreferences.setMockInitialValues({
      LocalAccountData.journalKey: jsonEncode({'id': 'user-a', 'data': data()}),
      LocalAccountData.activeKey: 'user-b',
      LocalAccountData.styleKey: 'satellite'
    });
    final prefs = await SharedPreferences.getInstance();
    final store = LocalAccountData(prefs);
    await store.recover();
    expect(store.activeId, 'user-a');
    expect(prefs.getString(LocalAccountData.styleKey), 'hybrid');
    expect(prefs.containsKey(LocalAccountData.journalKey), isFalse);
  });
  test('invalid remote preferences never partially overwrite local settings',
      () async {
    SharedPreferences.setMockInitialValues(
        {LocalAccountData.styleKey: 'satellite'});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalAccountData(prefs);
    await expectLater(
        store.replace(const AccountData(displayName: '', revision: -1)),
        throwsFormatException);
    expect(prefs.getString(LocalAccountData.styleKey), 'satellite');
  });
}
