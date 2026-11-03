import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/config/app_brand.dart';
import 'package:moto_nav_bridge/config/ble_constants.dart';

void main() {
  test('public product and display names are NAVIO', () {
    expect(AppBrand.name, 'NAVIO');
    expect(AppBrand.displayName('001122334455'), 'NAVIO-001122334455');
  });

  test('NAVIO and legacy displays remain discoverable', () {
    for (final name in [
      'NAVIO-001122334455',
      'NAV-001122334455',
      'ESP32_NAV',
    ]) {
      expect(BleConstants.matchesAdvertisedName(name), isTrue, reason: name);
    }
    for (final name in ['NAVIO', 'NAVIO-0011', 'NAVIO-00112233445Z', 'Other']) {
      expect(BleConstants.matchesAdvertisedName(name), isFalse, reason: name);
    }
    // Branding must not break the protocol of already paired hardware.
    expect(BleConstants.serviceUuid, '12345678-1234-1234-1234-123456789abc');
    expect(
      BleConstants.characteristicUuid,
      'abcd1234-5678-1234-5678-abcdef123456',
    );
    expect(
      BleConstants.pairingCharacteristicUuid,
      'abcd1234-5678-1234-5678-abcdef123457',
    );
  });

  test(
    'platform display names use NAVIO without replacing installed app IDs',
    () {
      String read(String path) => File(path).readAsStringSync();
      final ios = read('ios/Runner/Info.plist');
      expect(
        ios,
        matches(RegExp(r'CFBundleDisplayName</key>\s*<string>NAVIO</string>')),
      );
      expect(
        ios,
        matches(RegExp(r'CFBundleName</key>\s*<string>NAVIO</string>')),
      );
      expect(
        ios,
        contains('Connect to your NAVIO motorcycle navigation display'),
      );
      expect(
        read('ios/Runner.xcodeproj/project.pbxproj'),
        contains('com.williamli.motonav'),
      );
      expect(
        read('android/app/src/main/AndroidManifest.xml'),
        contains('android:label="NAVIO"'),
      );
      expect(read('web/manifest.json'), contains('"short_name": "NAVIO"'));
      expect(read('web/index.html'), contains('<title>NAVIO</title>'));
      expect(
        read('macos/Runner/Configs/AppInfo.xcconfig'),
        contains('PRODUCT_NAME = NAVIO'),
      );
      expect(
        read('linux/runner/my_application.cc'),
        contains('gtk_window_set_title(window, "NAVIO")'),
      );
      expect(
        read('windows/runner/main.cpp'),
        contains('window.Create(L"NAVIO"'),
      );
      expect(
        read('windows/runner/Runner.rc'),
        contains('"ProductName", "NAVIO"'),
      );
    },
  );

  test('firmware standby and advertised name match the app brand', () {
    final pages = File(
      '../firmware/platformio/ui_screens.cpp',
    ).readAsStringSync();
    expect(pages, contains('drawRoundCenteredStatus("NAVIO",'));
    expect(pages, contains('drawStandbyBrandText("NAVIO",'));
    expect(pages, isNot(contains('"NAVO"')));
    final firmware = File(
      '../firmware/esp32_nav_display/esp32_nav_display.ino',
    ).readAsStringSync();
    expect(firmware, contains('"NAVIO-%s", deviceIdentity'));
    expect(firmware, contains('[TFT] NAVIO UI:'));
  });
}
