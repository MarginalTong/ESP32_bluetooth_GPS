import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../config/ble_constants.dart';
import '../models/nav_state.dart';
import 'ble/ble_link_health.dart';
import 'ble/ble_reconnect_policy.dart';
import 'navigation_ports.dart';
import 'packet_signer.dart';
import 'send_throttle.dart';
import 'display_binding.dart';
import 'display_binding_store.dart';

part 'ble/ble_scan.dart';
part 'ble/ble_pairing.dart';
part 'ble/ble_writes.dart';

enum BleConnectionState {
  idle,
  scanning,
  connecting,
  awaitingBoot,
  connected,
  disconnected,
}

/// Owns the BLE link to the NAVIO display: scan -> connect -> discover
/// the write characteristic -> push [NavState] payloads (throttled).
///
/// Navigation is write-only; a separate read/write characteristic confirms a
/// physical BOOT press before the first binding is saved on this phone.
class BleService extends ChangeNotifier implements NavigationBlePort {
  BleService({SendThrottle? throttle, DisplayBindingStore? bindingStore})
    : _throttle = throttle ?? SendThrottle(),
      _bindingStore = bindingStore ?? DisplayBindingStore() {
    _adapterSub = FlutterBluePlus.adapterState.listen((s) {
      // CoreBluetooth reports `unknown` briefly while iOS is restoring its
      // state. Treating that transitional value as Bluetooth-off tears down a
      // valid connection during app launch/resume.
      if (s == BluetoothAdapterState.on) {
        // Bluetooth came back: resume looking for the display at once.
        if (_maintainConnection && _state != BleConnectionState.connected) {
          _reconnectAttempt = 0;
          _scheduleReconnect();
        }
      } else if (s != BluetoothAdapterState.unknown) {
        // Nothing can connect until it is on again; keep the message up.
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _characteristic = null;
        _signer = null;
        _throttle.reset();
        if (_state == BleConnectionState.scanning ||
            _state == BleConnectionState.connecting ||
            _state == BleConnectionState.awaitingBoot ||
            _state == BleConnectionState.connected) {
          _setState(
            BleConnectionState.disconnected,
            error: 'Bluetooth is ${s.name}. Turn it on and reconnect.',
          );
        }
      }
    });
  }

  final SendThrottle _throttle;
  final DisplayBindingStore _bindingStore;

  BleConnectionState _state = BleConnectionState.idle;
  BleConnectionState get state => _state;

  String? _lastError;
  String? get lastError => _lastError;

  /// When [lastError] was set; null when there is none.
  DateTime? _lastErrorAt;
  DateTime? get lastErrorAt => _lastErrorAt;

  /// [lastError] text when the display refused pairing because its power-up
  /// pairing window had closed; the user has to replug it.
  static const String pairingWindowClosed = 'Display pairing window closed';
  static bool isPairingWindowClosed(String? error) =>
      error?.contains(pairingWindowClosed) ?? false;

  /// The connecting display confirms pairing by being powered up (no button),
  /// not by a BOOT press. Reported by the display on every pairing read.
  bool _confirmsByPower = false;
  bool get confirmsByPower => _confirmsByPower;

  /// Prefix of [lastError] after a navigation write was not acknowledged.
  static const String writeFailurePrefix = 'Write failed:';

  /// A failed write is reported as current only this long. The message stays
  /// (with its age) until a later write succeeds, but an old failure must not
  /// look like the link is broken now.
  static const Duration recentWriteFailure = Duration(seconds: 30);
  Timer? _writeFailureFade;

  static bool isWriteFailure(String? error) =>
      error?.startsWith(writeFailurePrefix) ?? false;

  /// Whether [error] is a write failure from within [recentWriteFailure].
  /// An unknown time counts as recent.
  static bool isRecentWriteFailure(String? error, DateTime? at, DateTime now) =>
      isWriteFailure(error) &&
      (at == null || now.difference(at) < recentWriteFailure);

  /// Per-write timing, for the diagnostics log: payload size, negotiated MTU,
  /// whether the payload needed a long (prepared) write, and how long the
  /// display took to acknowledge it. Never contains the payload itself.
  final List<String> _diagnostics = [];
  String get diagnostics => _diagnostics.join('\n');
  void clearDiagnostics() => _diagnostics.clear();

  void _log(String event) {
    _diagnostics.add('${DateTime.now().toUtc().toIso8601String()} ble $event');
    if (_diagnostics.length > 200) _diagnostics.removeAt(0);
  }

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
  static const _reconnectPolicy = BleReconnectPolicy();
  final BleLinkHealth _linkHealth = BleLinkHealth();
  bool _disposed = false;
  String? _boundRemote;
  String? _boundIdentity;
  Uint8List? _boundKey;
  // Signs this connection's writes; replaced on every connection because the
  // display issues a fresh session nonce each time.
  PacketSigner? _signer;
  bool _legacyBindingDropped = false;
  Future<BluetoothDevice?> Function(List<ScanResult>)? _chooseDevice;
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
    await _bindingStore.delete();
    _boundRemote = null;
    _boundIdentity = null;
    _boundKey = null;
    _lastSent = null;
    _pendingState = null;
    _setState(BleConnectionState.idle);
  }

  Future<void> _loadBinding() async {
    final data = await _bindingStore.read();
    if (data != null && !data.containsKey('key')) {
      // Saved before the display signed packets: it holds no key, so the
      // display would ignore every write. The store has already discarded
      // it; pair again with a BOOT press.
      _legacyBindingDropped = true;
    }
    if (data == null || !data.containsKey('key')) {
      _boundRemote = null;
      _boundIdentity = null;
      _boundKey = null;
      return;
    }
    final binding = DisplayBinding.fromJson(data);
    _boundRemote = binding.remote;
    _boundIdentity = binding.identity;
    _boundKey = binding.key;
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
    _lastErrorAt = error == null ? null : DateTime.now();
    _writeFailureFade?.cancel();
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
      _setState(
        BleConnectionState.disconnected,
        error: 'Cannot read saved display binding',
      );
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

  Completer<BluetoothDevice?>? _scanWait;

  @override
  Future<void> disconnect() async {
    _session++;
    _maintainConnection = false;
    // End a scan in progress now instead of after its full timeout, so
    // forgetting or replacing a display that is offline does not hang.
    final scan = _scanWait;
    if (scan != null && !scan.isCompleted) scan.complete(null);
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
    final adapter = FlutterBluePlus.adapterStateNow;
    if (adapter != BluetoothAdapterState.on &&
        adapter != BluetoothAdapterState.unknown) {
      return; // Resumed by the adapter listener when Bluetooth is on again.
    }

    // Retries continue until the display is back or the user disconnects;
    // the pace is set by BleReconnectPolicy.
    final delay = _reconnectPolicy.delay(_reconnectAttempt);
    _reconnectAttempt++;
    _setState(BleConnectionState.connecting);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || !_maintainConnection) return;
      unawaited(
        connect(
          timeout: BleReconnectPolicy.scanTimeout,
          resetReconnectAttempts: false,
        ),
      );
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
    _signer = null;
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

  /// Drops a connection that no longer answers and makes it again; see
  /// [BleLinkHealth].

  @override
  void dispose() {
    _session++;
    _disposed = true;
    _maintainConnection = false;
    _reconnectTimer?.cancel();
    _writeFailureFade?.cancel();
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
