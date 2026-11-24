part of '../ble_service.dart';

extension _BleScan on BleService {
  Future<void> _connectInternal(Duration timeout) async {
    if (!(await FlutterBluePlus.isSupported)) {
      _setState(BleConnectionState.idle, error: 'BLE not supported on device');
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _setState(
        BleConnectionState.idle,
        error: 'Bluetooth is ${adapterState.name}. Turn it on and reconnect.',
      );
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
    _scanWait = completer;
    final candidates = <String, ScanResult>{};
    Timer? candidateWindow;

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen(
      (results) {
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
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );

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
      _setState(
        BleConnectionState.idle,
        error: _legacyBindingDropped
            ? 'Display security was updated. Connect and press BOOT to pair again.'
            : _boundRemote == null
            ? 'No display selected. Tap to scan again.'
            : 'Bound display is offline. Other displays will not be connected.',
      );
      return;
    }

    await _connectTo(found);
  }

  Future<BluetoothDevice?> _findSystemDevice() async {
    try {
      final devices = await FlutterBluePlus.systemDevices([
        Guid(BleConstants.serviceUuid),
      ]);
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
    return BleConstants.matchesAdvertisedName(name) ||
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
}
