part of '../ble_service.dart';

extension _BleWrites on BleService {
  Future<bool> _beginWriteDrain() {
    late final Future<bool> operation;
    operation = _drainPendingWrites().whenComplete(() {
      if (identical(_writeOp, operation)) _writeOp = null;
    });
    return operation;
  }

  Future<bool> _drainPendingWrites() async {
    while (_state == BleConnectionState.connected &&
        _characteristic != null &&
        _pendingState != null) {
      final state = _pendingState!;
      _pendingState = null;
      final now = DateTime.now();
      if (!_throttle.shouldSend(state, now)) continue;
      final signer = _signer;
      final characteristic = _characteristic;
      if (signer == null) {
        _pendingState ??= state;
        return false;
      }

      final deadline = state.expiresAtUtcSeconds;
      if (deadline != null && deadline < now.millisecondsSinceEpoch ~/ 1000) {
        continue;
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
        await characteristic!.write(
          bytes,
          withoutResponse: BleConstants.writeWithoutResponse,
          allowLongWrite: BleConstants.allowLongWrite,
          timeout: BleLinkHealth.writeTimeoutSeconds,
        );
        if (!identical(_signer, signer) ||
            !identical(_characteristic, characteristic)) {
          return false;
        }
        _linkHealth.reset();
        _log('write ok $timing ms=${elapsed.elapsedMilliseconds}');
        _throttle.markSent(state, now);
        _lastSent = state;
        _lastError = null;
        _lastErrorAt = null;
        _writeFailureFade?.cancel();
        notifyListeners();
      } catch (e) {
        // An acknowledgement/error from the old connection cannot poison the
        // new session, requeue its state, or reset its healthy transport.
        if (!identical(_signer, signer) ||
            !identical(_characteristic, characteristic)) {
          return false;
        }
        _log(
          'write failed $timing ms=${elapsed.elapsedMilliseconds} '
          'type=${e.runtimeType}',
        );
        // Preserve the newest unsent instruction for the reconnect flush.
        _pendingState ??= state;
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
}
