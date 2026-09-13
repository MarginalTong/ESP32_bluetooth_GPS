import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config/ble_constants.dart';
import '../models/nav_state.dart';
import 'navigation_ports.dart';
import 'send_throttle.dart';

enum BleConnectionState { idle, scanning, connecting, connected, disconnected }

/// Owns the BLE link to the ESP32_NAV peripheral: scan -> connect -> discover
/// the write characteristic -> push [NavState] payloads (throttled).
///
/// The firmware characteristic is WRITE-only, so there is no notify/read path
/// and thus no application-level ACK. "Connected + write returned" is the
/// strongest delivery signal we have.
class BleService extends ChangeNotifier implements NavigationBlePort {
  BleService({SendThrottle? throttle})
      : _throttle = throttle ?? SendThrottle() {
    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      // CoreBluetooth reports `unknown` briefly while iOS is restoring its
      // state. Treating that transitional value as Bluetooth-off tears down a
      // valid connection during app launch/resume.
      if (s != BluetoothAdapterState.on && s != BluetoothAdapterState.unknown) {
        _characteristic = null;
        _throttle.reset();
        if (_state == BleConnectionState.scanning ||
            _state == BleConnectionState.connecting ||
            _state == BleConnectionState.connected) {
          _setState(BleConnectionState.disconnected,
              error: 'Bluetooth is ${s.name}. Turn it on and reconnect.');
        }
      }
    });
  }

  final SendThrottle _throttle;

  BleConnectionState _state = BleConnectionState.idle;
  BleConnectionState get state => _state;

  String? _lastError;
  String? get lastError => _lastError;

  NavState? _lastSent;
  NavState? get lastSent => _lastSent;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Future<void>? _connectOp;
  bool _disposed = false;

  void _setState(BleConnectionState s, {String? error}) {
    _state = s;
    _lastError = error;
    notifyListeners();
  }

  /// Scans for the ESP32_NAV device by name and connects to the first match.
  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    _connectOp ??= _connectInternal(timeout).whenComplete(() {
      _connectOp = null;
    });
    return _connectOp;
  }

  Future<void> _connectInternal(Duration timeout) async {
    if (!(await FlutterBluePlus.isSupported)) {
      _setState(BleConnectionState.idle, error: 'BLE not supported on device');
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _setState(BleConnectionState.idle,
          error:
              'Bluetooth is ${adapterState.name}. Turn it on and reconnect.');
      return;
    }

    await _stopActiveScan();

    if (_state == BleConnectionState.connected &&
        _device?.isConnected == true &&
        _characteristic != null) {
      _setState(BleConnectionState.connected);
      return;
    }

    // Do not let an old CoreBluetooth device/characteristic survive into a new
    // manual connect attempt. ESP32 resets, iOS background restoration, and
    // overnight idle can all leave this object stale even when the UI thinks it
    // is merely disconnected.
    await _releaseCurrentDevice(disconnectDevice: true);

    final cached = await _findSystemDevice();
    if (cached != null) {
      final connected = await _connectTo(cached);
      if (connected) return;
      // iOS can hand us a stale CoreBluetooth device after the app was killed
      // or the ESP32 restarted. If that direct reconnect fails, fall through
      // to a fresh scan instead of leaving the app stuck until the cable/power
      // is cycled.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    _setState(BleConnectionState.scanning);
    final completer = Completer<BluetoothDevice?>();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (_matchesDevice(r)) {
          if (!completer.isCompleted) completer.complete(r.device);
          return;
        }
      }
    }, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    try {
      // Match in `_matchesDevice` instead of filtering here. On iOS a service
      // filter only sees peripherals that include the UUID in their advertising
      // packet; many ESP32 sketches expose the service after connection but do
      // not advertise its UUID.
      await FlutterBluePlus.startScan(timeout: timeout);
    } catch (e) {
      await _scanSub?.cancel();
      _scanSub = null;
      _setState(BleConnectionState.idle, error: 'Scan failed: $e');
      return;
    }

    BluetoothDevice? found;
    try {
      found = await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (e) {
      _setState(BleConnectionState.idle, error: 'Scan failed: $e');
      return;
    } finally {
      await _stopActiveScan();
    }

    if (found == null) {
      _setState(BleConnectionState.idle,
          error: 'ESP32_NAV not found. Is it powered and advertising?');
      return;
    }

    await _connectTo(found);
  }

  Future<BluetoothDevice?> _findSystemDevice() async {
    try {
      final devices =
          await FlutterBluePlus.systemDevices([Guid(BleConstants.serviceUuid)]);
      for (final device in devices) {
        if (device.platformName == BleConstants.deviceName) return device;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('System BLE lookup failed: $e');
    }
    return null;
  }

  bool _matchesDevice(ScanResult result) {
    final serviceUuid = Guid(BleConstants.serviceUuid);
    return result.device.platformName == BleConstants.deviceName ||
        result.advertisementData.advName == BleConstants.deviceName ||
        result.advertisementData.serviceUuids.contains(serviceUuid);
  }

  Future<void> _stopActiveScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Stop scan failed: $e');
    }
    await _scanSub?.cancel();
    _scanSub = null;
  }

  Future<bool> _connectTo(BluetoothDevice device) async {
    _device = device;
    _setState(BleConnectionState.connecting);

    await _connSub?.cancel();
    _connSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) {
        _characteristic = null;
        _throttle.reset();
        _setState(BleConnectionState.disconnected);
      }
    });

    try {
      if (!device.isConnected) {
        await device.connect(timeout: const Duration(seconds: 10), mtu: null);
      }
      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == Guid(BleConstants.serviceUuid),
        orElse: () => throw Exception('Service not found on device'),
      );
      _characteristic = service.characteristics.firstWhere(
        (c) => c.uuid == Guid(BleConstants.characteristicUuid),
        orElse: () => throw Exception('Characteristic not found on device'),
      );
      _setState(BleConnectionState.connected);
      return true;
    } catch (e) {
      await _releaseCurrentDevice(disconnectDevice: true);
      _setState(BleConnectionState.disconnected, error: 'Connect failed: $e');
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    await _stopActiveScan();
    await _releaseCurrentDevice(disconnectDevice: true);
    _setState(BleConnectionState.disconnected);
  }

  Future<void> _releaseCurrentDevice({required bool disconnectDevice}) async {
    await _connSub?.cancel();
    _connSub = null;
    if (disconnectDevice) {
      try {
        await _device?.disconnect(queue: false);
      } catch (e) {
        if (kDebugMode) debugPrint('Disconnect failed: $e');
      }
    }
    _device = null;
    _characteristic = null;
    _throttle.reset();
  }

  /// Sends [state] if the throttle allows and we are connected.
  ///
  /// Returns true if a write was actually performed. Throttled or
  /// disconnected calls return false without error.
  @override
  Future<bool> send(NavState state) async {
    final ch = _characteristic;
    if (_state != BleConnectionState.connected || ch == null) return false;

    final now = DateTime.now();
    if (!_throttle.shouldSend(state, now)) return false;

    try {
      await ch.write(
        utf8.encode(state.toWire()),
        withoutResponse: BleConstants.writeWithoutResponse,
      );
      _throttle.markSent(state, now);
      _lastSent = state;
      _lastError = null;
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = 'Write failed: $e';
      if (kDebugMode) debugPrint(_lastError);
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _scanSub?.cancel();
    _connSub?.cancel();
    _adapterSub?.cancel();
    _device?.disconnect(queue: false);
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}
