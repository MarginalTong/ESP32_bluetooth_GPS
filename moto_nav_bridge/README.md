# Moto Nav Bridge

Navigation middleware for the ESP32 motorcycle navigation display.

## Valhalla 偏航重算

首次规划、预览和偏航重算统一使用 Valhalla 服务，传入可靠的移动航向。
Apple 地图保留为底图，展示 App 选中的路线，
与 ESP32 共用重算结果。本次没有嵌入离线引擎或地图包。

云端地址统一配置在 `lib/config/api_config.dart`：
`https://nav.williamligallery.uk`，通过 HTTPS 443 请求 `/route`。
不使用公共演示服务器，也不在 Valhalla 失败时回退 Apple。
旧 `VALHALLA_ROUTE_URL` 构建参数不再生效。仍需完成真机导航验证。

```sh
flutter run
```

详见 [配置、隐私与测试说明](docs/valhalla-rerouting.md)。

```
Valhalla /route → maneuver parse → NavigationEngine → NavState → BLE JSON → ESP32_NAV
```

The ESP32 stays a thin renderer. This Flutter app does the map API call, maps
Valhalla maneuvers to the device protocol (`LEFT`, `BEAR_RIGHT`,
`UTURN`, …), tracks GPS, and writes `{"dir":"LEFT","dist":200}` to the device
over BLE.

## Device contract (from the firmware)

- Device name: `NAV-<12 hex chip identity>` (legacy boards: `ESP32_NAV`)
- Service UUID: `12345678-1234-1234-1234-123456789abc`
- Characteristic UUID: `abcd1234-5678-1234-5678-abcdef123456` (WRITE, with response)
- Payload: signed JSON, `{"dir":"<DIR>","dist":<int>,...,"n":<counter>}|<16 hex>`,
  built by [lib/services/packet_signer.dart](lib/services/packet_signer.dart).
  The key comes from the BOOT-confirmed pairing and is stored in the display
  binding; the session nonce is read from the pairing characteristic on every
  connection. See `firmware/README.md` for the full contract.
- No notify channel → no application-level ACK.

These live in [lib/config/ble_constants.dart](lib/config/ble_constants.dart).

## Setup

This machine did not have Flutter installed, so the code was written but **not**
compiled or test-run here. On your machine:

1. Install Flutter: https://docs.flutter.dev/get-started/install
2. From `moto_nav_bridge/`, generate the platform folders (the `lib/`, `test/`,
   `pubspec.yaml` are provided; the iOS/Android runners are not):

   ```sh
   flutter create .
   ```

   Then re-apply the permission snippets below (they get overwritten by
   `flutter create`).
3. Fetch packages and run tests:

   ```sh
   flutter pub get
   flutter analyze
   flutter test
   ```
4. Run on a device with your reachable Valhalla endpoint:

   ```sh
   flutter run
   ```

## Required platform permissions

`flutter create .` regenerates these files — add the entries afterward.

### iOS — `ios/Runner/Info.plist`

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connect to the ESP32_NAV navigation display.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Track position to compute turn-by-turn directions.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Track position while navigating in the background.</string>
```

### Android — `android/app/src/main/AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

Set `minSdkVersion 21` (flutter_blue_plus / geolocator requirement) in
`android/app/build.gradle`.

## Architecture

| Layer | File | Notes |
|---|---|---|
| Protocol enum | `lib/models/device_direction.dart` | wire tokens match firmware byte-for-byte |
| Payload | `lib/models/nav_state.dart` | `toWire()` = exact BLE bytes |
| Directions | `lib/services/valhalla_directions_service.dart` | all route planning and Valhalla parsing |
| Engine | `lib/services/navigation_engine.dart` | position → step advance → NavState |
| Throttle | `lib/services/send_throttle.dart` | avoid flooding BLE |
| BLE | `lib/services/ble_service.dart` | scan/connect/write |
| Location | `lib/services/location_service.dart` | geolocator wrapper |
| Controller | `lib/controllers/navigation_controller.dart` | wires it all together |
| UI | `lib/ui/**` | connect, destination, live instruction mirror |

The pure-Dart layers (models, maneuver_mapper, navigation_engine, send_throttle,
directions parse) are covered by tests in `test/` and run without any device or
plugins.

## Maneuver → device mapping

| Google maneuver | device `dir` |
|---|---|
| turn-left, turn-sharp-left, ramp-left | LEFT |
| turn-right, turn-sharp-right, ramp-right | RIGHT |
| turn-slight-left, fork-left, keep-left, roundabout-left | BEAR_LEFT |
| turn-slight-right, fork-right, keep-right, roundabout-right | BEAR_RIGHT |
| uturn-left, uturn-right | UTURN |
| straight, merge, ferry, ferry-train, (none) | UP |
| final step / destination | ARRIVED |
| GPS lost / paused | STOP |
