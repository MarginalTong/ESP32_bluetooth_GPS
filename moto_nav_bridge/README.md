# Moto Nav Bridge

Navigation middleware for the ESP32 motorcycle navigation display.

```
Google Directions API → maneuver parse → protocol map → NavState → BLE JSON → ESP32_NAV
```

The ESP32 stays a thin renderer. This Flutter app does the map API call, maps
Google `maneuver` strings to the device protocol (`LEFT`, `BEAR_RIGHT`,
`UTURN`, …), tracks GPS, and writes `{"dir":"LEFT","dist":200}` to the device
over BLE.

## Device contract (from the firmware)

- Device name: `ESP32_NAV`
- Service UUID: `12345678-1234-1234-1234-123456789abc`
- Characteristic UUID: `abcd1234-5678-1234-5678-abcdef123456` (WRITE, with response)
- Payload: `{"dir":"<DIR>","dist":<int>}` — kept small (firmware buffer is 200 bytes)
- No notify/read channel → no application-level ACK. First write flips the
  firmware into LIVE mode.

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
4. Run on a device with your Google key:

   ```sh
   flutter run --dart-define=GOOGLE_DIRECTIONS_API_KEY=YOUR_KEY
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
| Maneuver map | `lib/services/maneuver_mapper.dart` | pure fn, fully unit-tested |
| Directions | `lib/services/directions_service.dart` | API call + `parseRouteJson` (testable) |
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
