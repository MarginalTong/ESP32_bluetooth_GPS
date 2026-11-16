import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/ble/ble_reconnect_policy.dart';

void main() {
  const policy = BleReconnectPolicy();

  test('a dropped link is retried quickly at first', () {
    expect(
      [for (var i = 0; i < 4; i++) policy.delay(i).inSeconds],
      [1, 2, 4, 8],
    );
  });

  test('retries never stop while the display is wanted', () {
    expect(policy.delay(4), const Duration(seconds: 10));
    expect(policy.delay(19), const Duration(seconds: 10));
    expect(policy.delay(20), const Duration(seconds: 30));
    expect(policy.delay(100000), const Duration(seconds: 30));
  });

  test('the steady pace covers about five minutes', () {
    var total = Duration.zero;
    for (var i = 0; i < 20; i++) {
      total += policy.delay(i) + BleReconnectPolicy.scanTimeout;
    }
    expect(total.inMinutes, inInclusiveRange(4, 6));
  });
}
