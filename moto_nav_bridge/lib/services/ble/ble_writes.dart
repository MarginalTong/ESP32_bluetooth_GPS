part of '../ble_service.dart';

extension _BleWrites on BleService {
  Future<bool> _drainPendingWrites() async {
    while (_state == BleConnectionState.connected &&
        _characteristic != null &&
        _pendingState != null) {
      final state = _pendingState!;
      _pendingState = null;
      _pendingStateAt = null;
      final now = DateTime.now();
      if (!_throttle.shouldSend(state, now)) continue;
      final signer = _signer;
      if (signer == null) {
        _pendingState ??= state;
        _pendingStateAt ??= now;
        return false;
      }

      final wire = signer.sign(state.toWire());
      if (kDebugMode) {
        debugPrint(
          '[BLE_NAV] ${utf8.encode(wire).length} bytes, '
          'route=${state.routePreviewPoints.length ~/ 2}, '
          'roads=${state.sideRoadPreviewPoints.length ~/ 4}',
        );
      }

      final bytes = utf8.encode(wire);
      final mtu = _device?.mtuNow ?? 0;
      final timing =
          'bytes=${bytes.length} mtu=$mtu '
          'long=${mtu > 0 && bytes.length > mtu - 3}';
      final elapsed = Stopwatch()..start();
      try {
        await _characteristic!.write(
          bytes,
          withoutResponse: BleConstants.writeWithoutResponse,
          allowLongWrite: BleConstants.allowLongWrite,
          timeout: BleLinkHealth.writeTimeoutSeconds,
        );
        _linkHealth.reset();
        _log('write ok $timing ms=${elapsed.elapsedMilliseconds}');
        _throttle.markSent(state, now);
        _lastSent = state;
        _lastError = null;
        _lastErrorAt = null;
        _writeFailureFade?.cancel();
        notifyListeners();
      } catch (e) {
        _log(
          'write failed $timing ms=${elapsed.elapsedMilliseconds} '
          'type=${e.runtimeType}',
        );
        // Preserve the newest unsent instruction for the reconnect flush.
        _pendingState ??= state;
        _pendingStateAt ??= now;
        _lastError = '${BleService.writeFailurePrefix} $e';
        _lastErrorAt = DateTime.now();
        // Let listeners show the failure as old once it stops being recent.
        _writeFailureFade?.cancel();
        _writeFailureFade = Timer(BleService.recentWriteFailure, () {
          if (!_disposed) notifyListeners();
        });
        if (kDebugMode) debugPrint(_lastError);
        notifyListeners();
        if (_linkHealth.writeFailed(linkError: BleLinkHealth.isLinkError(e))) {
          unawaited(_resetStaleLink());
        }
        return false;
      }
    }
    return true;
  }

  Future<void> _resetStaleLink() async {
    final session = _session;
    _log('link reset: writes unanswered');
    await _releaseCurrentDevice(disconnectDevice: true);
    if (_disposed || session != _session || !_maintainConnection) return;
    _setState(
      BleConnectionState.disconnected,
      error: 'BLE link stopped responding',
    );
    _scheduleReconnect();
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
}
