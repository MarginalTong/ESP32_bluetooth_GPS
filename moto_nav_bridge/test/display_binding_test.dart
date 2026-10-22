import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/display_binding.dart';

void main() {
  const key = '000102030405060708090a0b0c0d0e0f';

  test('both transport and complete screen identity must match', () {
    final binding = DisplayBinding.fromJson(
        {'remote': 'phone-device-A', 'identity': '001122334455', 'key': key});
    expect(binding.matches('phone-device-A', '001122334455'), true);
    expect(binding.matches('phone-device-B', '001122334455'), false);
    expect(binding.matches('phone-device-A', 'AA1122334455'), false);
  });

  test('the display key round-trips through storage', () {
    final binding = DisplayBinding.fromJson(
        {'remote': 'phone-device-A', 'identity': '001122334455', 'key': key});
    expect(binding.key, List.generate(16, (i) => i));
    expect(binding.toJson()['key'], key);
  });

  test('corrupt or partial binding fails closed', () {
    for (final data in <Map<String, dynamic>>[
      {},
      {'remote': '', 'identity': '001122334455', 'key': key},
      {'remote': 'a', 'identity': '4455', 'key': key},
      {'remote': 'a', 'identity': null, 'key': key},
      {'remote': 'a', 'identity': '001122334455', 'key': 'abcd'},
    ]) {
      expect(() => DisplayBinding.fromJson(data), throwsFormatException);
    }
  });

  test('a binding saved before signed packets must be paired again', () {
    expect(
        () => DisplayBinding.fromJson(
            {'remote': 'phone-device-A', 'identity': '001122334455'}),
        throwsFormatException);
  });
}
