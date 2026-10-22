import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ble_constants.dart';
import '../models/nav_state.dart';
import 'navigation_ports.dart';
import 'send_throttle.dart';
import 'display_binding.dart';

enum BleConnectionState {
  idle,
  scanning,
  connecting,
  awaitingBoot,
  connected,
  disconnected
}

/// Owns the BLE link to the ESP32_NAV peripheral: scan -> connect -> discover
/// the write characteristic -> push [NavState] payloads (throttled).
///
/// Navigation is write-only; a separate read/write characteristic confirms a
/// physical BOOT press before the first binding is saved on this phone.
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
            _state == BleConnectionState.awaitingBoot ||
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
  Future<bool>? _writeOp;
  Timer? _reconnectTimer;
  NavState? _pendingState;
  DateTime? _pendingStateAt;
  bool _maintainConnection = false;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  String? _boundRemote;
  String? _boundIdentity;
  Future<BluetoothDevice?> Function(List<ScanResult>)? _chooseDevice;
  static const _bindingKey = 'nav_display_binding_v1';
  int _session = 0;
  bool _loadingBinding = false;
  String? get boundIdentity => _boundIdentity;
  Future<void> refreshBinding() async {
    await _loadBinding();
    notifyListeners();
  }

  Future<void> forgetDevice() async {
    await disconnect();
    // Let cancelled connection work finish before allowing another device.
    await _connectOp;
    if (!await (await SharedPreferences.getInstance()).remove(_bindingKey)) {
      throw StateError('Could not remove saved binding');
    }
    _boundRemote = null;
    _boundIdentity = null;
    _lastSent = null;
    _pendingState = null;
    _setState(BleConnectionState.idle);
  }

  Future<void> _loadBinding() async {
    final raw = (await SharedPreferences.getInstance()).getString(_bindingKey);
    if (raw == null) {
      _boundRemote = null;
      _boundIdentity = null;
      return;
    }
    final binding =
        DisplayBinding.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    _boundRemote = binding.remote;
    _boundIdentity = binding.identity;
  }

  void _setState(BleConnectionState s, {String? error}) {
    if (s == BleConnectionState.disconnected) {
      // The display clears its turn on link loss. Do not replay a pre-loss
      // instruction as soon as CoreBluetooth reconnects.
      _pendingState = null;
      _pendingStateAt = null;
    }
    _state = s;
    _lastError = error;
    notifyListeners();
  }

  /// First use requires manual selection; reconnects never select a stranger.
  Future<void> connect({
    Duration timeout = const Duration(seconds: 15),
    bool resetReconnectAttempts = true,
    Future<BluetoothDevice?> Function(List<ScanResult>)? chooseDevice,
  }) async {
    if (_connectOp != null || _loadingBinding) return;
    final session = _session;
    _loadingBinding = true;
    _setState(BleConnectionState.connecting);
    _chooseDevice = chooseDevice;
    try {
      await _loadBinding();
    } catch (_) {
      _setState(BleConnectionState.disconnected,
          error: 'Cannot read saved display binding');
      return; // Never silently treat a broken binding as an unbound phone.
    } finally {
      _loadingBinding = false;
    }
    if (_disposed || session != _session) return;
    _maintainConnection = true;
    if (resetReconnectAttempts) _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectOp ??= _connectInternal(timeout).whenComplete(() {
      _connectOp = null;
    });
    await _connectOp;
    if (_maintainConnection && _state != BleConnectionState.connected) {
      _scheduleReconnect();
    }
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

    final cached = _boundRemote == null ? null : await _findSystemDevice();
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
    final candidates = <String, ScanResult>{};
    Timer? candidateWindow;

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (_matchesDevice(r)) {
          if (_boundRemote == null) {
            candidates[r.device.remoteId.str] = r;
            candidateWindow ??= Timer(const Duration(milliseconds: 1100), () {
              if (!completer.isCompleted) completer.complete(null);
            });
          } else if (r.device.remoteId.str == _boundRemote) {
            if (!completer.isCompleted) completer.complete(r.device);
            return;
          }
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
      candidateWindow?.cancel();
      await _stopActiveScan();
    }

    if (!_maintainConnection || _disposed) return;
    if (_boundRemote == null &&
        candidates.isNotEmpty &&
        _chooseDevice != null) {
      found = await _chooseDevice!(candidates.values.toList());
      if (!_maintainConnection || _disposed) return;
    }

    if (found == null) {
      _setState(BleConnectionState.idle,
          error: _boundRemote == null
              ? 'No display selected. Tap to scan again.'
              : 'Bound display is offline. Other displays will not be connected.');
      return;
    }

    await _connectTo(found);
  }

  Future<BluetoothDevice?> _findSystemDevice() async {
    try {
      final devices =
          await FlutterBluePlus.systemDevices([Guid(BleConstants.serviceUuid)]);
      for (final device in devices) {
        if (device.remoteId.str == _boundRemote) return device;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('System BLE lookup failed: $e');
    }
    return null;
  }

  bool _matchesDevice(ScanResult result) {
    final serviceUuid = Guid(BleConstants.serviceUuid);
    final name = result.advertisementData.advName.isNotEmpty
        ? result.advertisementData.advName
        : result.device.platformName;
    return name == BleConstants.deviceName ||
        RegExp(r'^NAV-[0-9A-F]{12}$').hasMatch(name) ||
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
    final session = _session;
    _device = device;
    _setState(BleConnectionState.connecting);

    await _connSub?.cancel();
    bool ready = false;
    _connSub = device.connectionState.listen((s) {
      if (_disposed || session != _session) return;
      if (s == BluetoothConnectionState.disconnected) {
        // The stream immediately replays its initial disconnected value.
        // During connection/discovery, failures are handled by the await/catch
        // below; they are not an established link being lost.
        if (!ready) return;
        final reason = device.disconnectReason;
        final detail = reason == null
            ? 'BLE link disconnected'
            : 'BLE disconnected (${reason.code}: ${reason.description})';
        if (kDebugMode) debugPrint('[BLE] $detail');
        _characteristic = null;
        _throttle.reset();
        _setState(BleConnectionState.disconnected, error: detail);
        _scheduleReconnect();
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
      final pairing = service.characteristics.firstWhere(
        (c) => c.uuid == Guid('abcd1234-5678-1234-5678-abcdef123457'),
        orElse: () => throw Exception('Update display firmware before binding'),
      );
      Future<Map<String, dynamic>> status() async =>
          jsonDecode(utf8.decode(await pairing.read())) as Map<String, dynamic>;
      final identity = (await status())['id'] as String;
      if (session != _session || !_maintainConnection || _disposed) {
        return false;
      }
      if (_boundRemote != null) {
        if (!DisplayBinding(_boundRemote!, _boundIdentity!)
            .matches(device.remoteId.str, identity)) {
          throw Exception('Display identity mismatch');
        }
      } else {
        await pairing.write(utf8.encode('{"pair":"start"}'));
        _setState(BleConnectionState.awaitingBoot);
        var confirmed = false;
        for (var attempt = 0; attempt < 100; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          if (session != _session || !_maintainConnection || _disposed) {
            throw Exception('Binding cancelled');
          }
          final result = await status();
          if (result['id'] != identity) {
            throw Exception('Display identity changed during pairing');
          }
          if (result['verified'] == true) {
            confirmed = true;
            break;
          }
        }
        if (!confirmed) throw Exception('BOOT confirmation timed out');
        final saved = await (await SharedPreferences.getInstance()).setString(
            _bindingKey,
            jsonEncode({'remote': device.remoteId.str, 'identity': identity}));
        if (!saved) throw Exception('Could not save display binding');
        _boundRemote = device.remoteId.str;
        _boundIdentity = identity;
      }
      if (!_maintainConnection || _disposed || !device.isConnected) {
        throw Exception('Connection cancelled');
      }
      // Sync before publishing connected, so navigation writes cannot overlap.
      // A clock packet is independent of the navigation state and throttle.
      final now = DateTime.now();
      final localSeconds =
          now.millisecondsSinceEpoch ~/ 1000 + now.timeZoneOffset.inSeconds;
      await _characteristic!.write(
        utf8.encode(jsonEncode({'clock': localSeconds})),
        withoutResponse: BleConstants.writeWithoutResponse,
      );
      _reconnectAttempt = 0;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      ready = true;
      _setState(BleConnectionState.connected);
      unawaited(_flushPendingState());
      return true;
    } catch (e) {
      await _releaseCurrentDevice(disconnectDevice: true);
      _setState(BleConnectionState.disconnected, error: 'Connect failed: $e');
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    _session++;
    _maintainConnection = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pendingState = null;
    await _stopActiveScan();
    await _releaseCurrentDevice(disconnectDevice: true);
    _setState(BleConnectionState.disconnected);
  }

  void _scheduleReconnect() {
    if (_disposed ||
        !_maintainConnection ||
        _reconnectTimer != null ||
        _boundRemote == null) {
      return;
    }
    if (_state == BleConnectionState.connected || _connectOp != null) return;

    // Retry only four times after a transient radio drop. If the display has
    // genuinely lost power, stop after the 8-second attempt instead of
    // scanning forever and wasting the phone battery. A manual Connect starts
    // a fresh sequence.
    const delays = [1, 2, 4, 8];
    if (_reconnectAttempt >= delays.length) return;
    final seconds = delays[_reconnectAttempt];
    _reconnectAttempt++;
    _setState(BleConnectionState.connecting);
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      if (_disposed || !_maintainConnection) return;
      unawaited(connect(
        timeout: const Duration(seconds: 8),
        resetReconnectAttempts: false,
      ));
    });
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
    _pendingState = state;
    _pendingStateAt = DateTime.now();
    if (_state != BleConnectionState.connected || _characteristic == null) {
      return false;
    }

    // Exactly one drain loop owns the characteristic. New GPS/map updates
    // merely replace `_pendingState`, so a slow acknowledged BLE write cannot
    // build a queue of obsolete instructions or create concurrent writes.
    // A failed write ends this call: the newest state stays pending and is
    // retried by the next update or the reconnect flush, never in a hot loop.
    bool succeeded;
    do {
      _writeOp ??= _drainPendingWrites().whenComplete(() => _writeOp = null);
      succeeded = await _writeOp!;
    } while (succeeded &&
        _state == BleConnectionState.connected &&
        _characteristic != null &&
        _pendingState != null);
    return _lastSent == state;
  }

  /// Returns false when a write failed and the drain stopped early.
  Future<bool> _drainPendingWrites() async {
    while (_state == BleConnectionState.connected &&
        _characteristic != null &&
        _pendingState != null) {
      final state = _pendingState!;
      _pendingState = null;
      _pendingStateAt = null;
      final now = DateTime.now();
      if (!_throttle.shouldSend(state, now)) continue;

      final wire = state.toWire();
      if (kDebugMode) {
        debugPrint(
          '[BLE_NAV] ${utf8.encode(wire).length} bytes, '
          'route=${state.routePreviewPoints.length ~/ 2}, '
          'roads=${state.sideRoadPreviewPoints.length ~/ 4}',
        );
      }

      try {
        await _characteristic!.write(
          utf8.encode(wire),
          withoutResponse: BleConstants.writeWithoutResponse,
        );
        _throttle.markSent(state, now);
        _lastSent = state;
        _lastError = null;
        notifyListeners();
      } catch (e) {
        // Preserve the newest unsent instruction for the reconnect flush.
        _pendingState ??= state;
        _pendingStateAt ??= now;
        _lastError = 'Write failed: $e';
        if (kDebugMode) debugPrint(_lastError);
        notifyListeners();
        return false;
      }
    }
    return true;
  }

  Future<void> _flushPendingState() async {
    final pending = _pendingState;
    final age = _pendingStateAt == null
        ? null
        : DateTime.now().difference(_pendingStateAt!);
    if (pending != null && age != null && age < const Duration(seconds: 10)) {
      await send(pending);
    } else {
      _pendingState = null;
      _pendingStateAt = null;
    }
  }

  @override
  void dispose() {
    _session++;
    _disposed = true;
    _maintainConnection = false;
    _reconnectTimer?.cancel();
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
