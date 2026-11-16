import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/services/ble/ble_link_health.dart';

void main() {
  test('three unanswered writes in a row mean the link is dead', () {
    final health = BleLinkHealth();
    expect(health.writeFailed(linkError: true), isFalse);
    expect(health.writeFailed(linkError: true), isFalse);
    expect(health.writeFailed(linkError: true), isTrue);
    // Counting starts again for the new connection.
    expect(health.writeFailed(linkError: true), isFalse);
  });

  test('an acknowledged write clears earlier failures', () {
    final health = BleLinkHealth();
    health.writeFailed(linkError: true);
    health.writeFailed(linkError: true);
    health.reset();
    expect(health.writeFailed(linkError: true), isFalse);
  });

  test('a write the display refused proves the link works', () {
    final health = BleLinkHealth();
    health.writeFailed(linkError: true);
    health.writeFailed(linkError: true);
    expect(health.writeFailed(linkError: false), isFalse);
    expect(health.writeFailed(linkError: true), isFalse);
    for (var i = 0; i < 10; i++) {
      expect(health.writeFailed(linkError: false), isFalse);
    }
  });

  test('only a write with no answer is a link error', () {
    FlutterBluePlusException fbp(ErrorPlatform platform, int code) =>
        FlutterBluePlusException(platform, 'writeCharacteristic', code, 'x');
    expect(
      BleLinkHealth.isLinkError(
        fbp(ErrorPlatform.fbp, FbpErrorCode.timeout.index),
      ),
      isTrue,
    );
    expect(
      BleLinkHealth.isLinkError(
        fbp(ErrorPlatform.fbp, FbpErrorCode.deviceIsDisconnected.index),
      ),
      isTrue,
    );
    expect(BleLinkHealth.isLinkError(TimeoutException('write')), isTrue);
    // A GATT error from the display, e.g. a packet it rejected.
    expect(BleLinkHealth.isLinkError(fbp(ErrorPlatform.apple, 1)), isFalse);
    expect(
      BleLinkHealth.isLinkError(
        fbp(ErrorPlatform.fbp, FbpErrorCode.adapterIsOff.index),
      ),
      isFalse,
    );
    expect(BleLinkHealth.isLinkError(StateError('other')), isFalse);
  });
}
