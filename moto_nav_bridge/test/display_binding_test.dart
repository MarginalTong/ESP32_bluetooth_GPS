import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/display_binding.dart';

void main() {
  test('both transport and complete screen identity must match', () {
    final binding = DisplayBinding.fromJson(
        {'remote': 'phone-device-A', 'identity': '001122334455'});
    expect(binding.matches('phone-device-A', '001122334455'), true);
    expect(binding.matches('phone-device-B', '001122334455'), false);
    expect(binding.matches('phone-device-A', 'AA1122334455'), false);
  });
  test('corrupt or partial binding fails closed', () {
    for (final data in <Map<String, dynamic>>[
      {},
      {'remote': '', 'identity': '001122334455'},
      {'remote': 'a', 'identity': '4455'},
      {'remote': 'a', 'identity': null},
    ]) {
      expect(() => DisplayBinding.fromJson(data), throwsFormatException);
    }
  });
}
