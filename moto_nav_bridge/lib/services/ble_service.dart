import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config/ble_constants.dart';
import '../models/nav_state.dart';
import 'send_throttle.dart';

enum BleConnectionState { idle, scanning, connecting, connected, disconnected }

/// Owns the BLE link to the ESP32_NAV peripheral: scan -> connect -> discover
/// the write characteristic -> push [NavState] payloads (throttled).
///
/// The firmware characteristic is WRITE-only, so there is no notify/read path
/// and thus no application-level ACK. "Connected + write returned" is the
/// strongest delivery signal we have.
class BleService extends ChangeNotifier {
  BleService({SendThrottle? throttle})
      : _throttle = throttle ?? SendThrottle();

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

  void _setState(BleConnectionState s, {String? error}) {
    _state = s;
    _lastError = error;
    notifyListeners();
  }

  /// Scans for the ESP32_NAV device by name and connects to the first match.
  Future<void> connect({Duration timeout = const Duration(seconds: 15)}) async {
    if (_state == BleConnectionState.scanning ||
        _state == BleConnectionState.connecting) {
      return;
    }

    if (!(await FlutterBluePlus.isSupported)) {
      _setState(BleConnectionState.idle, error: 'BLE not supported on device');
      return;
    }

    _setState(BleConnectionState.scanning);
    final completer = Completer<BluetoothDevice?>();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName;
        if (name == BleConstants.deviceName) {
          if (!completer.isCompleted) completer.complete(r.device);
          return;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(BleConstants.serviceUuid)],
        timeout: timeout,
      );
    } catch (e) {
      // Fall back to name-only scan if service filtering is unsupported.
      try {
        await FlutterBluePlus.startScan(timeout: timeout);
      } catch (e2) {
        await _scanSub?.cancel();
        _setState(BleConnectionState.idle, error: 'Scan failed: $e2');
        return;
      }
    }

    final found = await completer.future
        .timeout(timeout, onTimeout: () => null)
        .whenComplete(() async {
      await FlutterBluePlus.stopScan();
      await _scanSub?.cancel();
    });

    if (found == null) {
      _setState(BleConnectionState.idle,
          error: 'ESP32_NAV not found. Is it powered and advertising?');
      return;
    }

    await _connectTo(found);
  }

  Future<void> _connectTo(BluetoothDevice device) async {
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
      await device.connect(timeout: const Duration(seconds: 10));
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
    } catch (e) {
      _setState(BleConnectionState.disconnected, error: 'Connect failed: $e');
    }
  }

  Future<void> disconnect() async {
    await _connSub?.cancel();
    await _device?.disconnect();
    _characteristic = null;
    _throttle.reset();
    _setState(BleConnectionState.disconnected);
  }

  /// Sends [state] if the throttle allows and we are connected.
  ///
  /// Returns true if a write was actually performed. Throttled or
  /// disconnected calls return false without error.
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
    _scanSub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }
}
