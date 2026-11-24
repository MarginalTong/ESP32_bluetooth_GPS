part of '../ble_service.dart';

extension _BlePairing on BleService {
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
        _signer = null;
        _throttle.reset();
        _setState(BleConnectionState.disconnected, error: detail);
        _scheduleReconnect();
      }
    });

    try {
      if (!device.isConnected) {
        // Android starts at the 23-byte minimum MTU (20-byte writes), far too
        // small for a signed packet; ask for a large one. iOS negotiates its
        // own MTU and ignores this.
        await device.connect(
          timeout: const Duration(seconds: 10),
          mtu: BleConstants.requestMtu,
        );
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
        (c) => c.uuid == Guid(BleConstants.pairingCharacteristicUuid),
        orElse: () => throw Exception('Update display firmware before binding'),
      );
      Future<Map<String, dynamic>> status() async =>
          jsonDecode(utf8.decode(await pairing.read())) as Map<String, dynamic>;
      final first = await status();
      final identity = first['id'] as String;
      _confirmsByPower = first['confirm'] == 'power';
      // A small uptime after a dropped link means the display restarted.
      final boot = first['boot'];
      final up = first['up'];
      if (boot is String && up is int) {
        _log(
          'device boot=${boot.replaceAll(RegExp(r'[^a-z_]'), '')} up=${up}s',
        );
      }
      // New every connection; without it this is pre-signing firmware.
      final nonce = PacketSigner.parseHex(first['s'], PacketSigner.nonceBytes);
      if (nonce == null) {
        throw Exception('Update display firmware before binding');
      }
      if (session != _session || !_maintainConnection || _disposed) {
        return false;
      }
      Uint8List? key;
      if (_boundRemote != null) {
        if (!DisplayBinding(
          _boundRemote!,
          _boundIdentity!,
          _boundKey!,
        ).matches(device.remoteId.str, identity)) {
          throw Exception('Display identity mismatch');
        }
        key = _boundKey;
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
          if (result['replug'] == true) {
            throw Exception(BleService.pairingWindowClosed);
          }
          if (result['verified'] == true) {
            // Issued only on the connection where BOOT was just pressed.
            key = PacketSigner.parseHex(result['k'], PacketSigner.keyBytes);
            if (key == null) throw Exception('Display issued no pairing key');
            confirmed = true;
            break;
          }
        }
        if (!confirmed) throw Exception('BOOT confirmation timed out');
        final binding = DisplayBinding(device.remoteId.str, identity, key!);
        await _bindingStore.write(binding);
        _boundRemote = binding.remote;
        _boundIdentity = binding.identity;
        _boundKey = binding.key;
        _legacyBindingDropped = false;
      }
      if (!_maintainConnection || _disposed || !device.isConnected) {
        throw Exception('Connection cancelled');
      }
      _signer = PacketSigner(key: key!, sessionNonce: nonce);
      // Sync before publishing connected, so navigation writes cannot overlap.
      // A clock packet is independent of the navigation state and throttle.
      final now = DateTime.now();
      final localSeconds =
          now.millisecondsSinceEpoch ~/ 1000 + now.timeZoneOffset.inSeconds;
      await _characteristic!.write(
        utf8.encode(
          _signer!.sign(
            jsonEncode({
              'clock': localSeconds,
              'utc': now.millisecondsSinceEpoch ~/ 1000,
            }),
          ),
        ),
        withoutResponse: BleConstants.writeWithoutResponse,
        allowLongWrite: BleConstants.allowLongWrite,
      );
      _reconnectAttempt = 0;
      _linkHealth.reset();
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      ready = true;
      // Reconnection is not permission to replay a pre-loss instruction.
      // NavigationContinuityController requests GPS-backed resynchronisation.
      _pendingState = null;
      _writeOp = null;
      _throttle.reset();
      _setState(BleConnectionState.connected);
      return true;
    } catch (e) {
      await _releaseCurrentDevice(disconnectDevice: true);
      _setState(BleConnectionState.disconnected, error: 'Connect failed: $e');
      return false;
    }
  }
}
