import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_text.dart';
import 'glass_panel.dart';
import '../../services/ble_service.dart';
import '../device_pairing.dart';

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    final text = AppText.of(context);
    final connected = ble.state == BleConnectionState.connected;
    final busy = ble.state == BleConnectionState.scanning ||
        ble.state == BleConnectionState.connecting ||
        ble.state == BleConnectionState.awaitingBoot;
    // An old write failure is history, not the link's current state.
    final writeFailed = !busy &&
        BleService.isRecentWriteFailure(
            ble.lastError, ble.lastErrorAt, DateTime.now());
    final hasError = !busy &&
        ble.lastError != null &&
        (writeFailed || !BleService.isWriteFailure(ble.lastError));
    final colors = Theme.of(context).colorScheme;
    final issue = !hasError
        ? null
        : writeFailed
            ? (text.displayUpdateInterrupted, text.reconnectDisplayHint)
            : _issue(text, ble.lastError!);

    return GlassPanel(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: busy
            ? null
            : () => connected ? ble.disconnect() : connectDisplay(context, ble),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected
                      ? const Color(0xff34c759)
                      : busy
                          ? colors.primary
                          : colors.outline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      issue != null
                          ? issue.$1
                          : connected
                              ? text.readyToGo
                              : busy
                                  ? text.connectingDisplay
                                  : text.tapToConnect,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.start,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      busy
                          ? _label(context, ble.state)
                          : issue?.$2 ?? _label(context, ble.state),
                      textAlign: TextAlign.start,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (busy)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  connected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: colors.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Short title and hint for a connection error; the raw text stays on the
  /// device page. A "not selected" scan is not a fault, so it has no issue.
  (String, String)? _issue(AppText text, String error) {
    if (error.startsWith('No display selected')) return null;
    if (error.startsWith('Bluetooth is')) {
      return (text.bluetoothOff, text.bluetoothOffHint);
    }
    if (error.startsWith('Bound display is offline') ||
        error.startsWith('Connect failed')) {
      return (text.displayOffline, text.displayOfflineHint);
    }
    if (error.startsWith('BLE ')) {
      return (text.displayDisconnected, text.displayDisconnectedHint);
    }
    if (error.startsWith('Display security')) {
      return (text.pairDisplayAgain, text.pairDisplayAgainHint);
    }
    return (text.deviceConnectionIssue, text.deviceDetailsHint);
  }

  String _label(BuildContext context, BleConnectionState state) {
    final text = AppText.of(context);
    return switch (state) {
      BleConnectionState.idle => text.displayNotConnected,
      BleConnectionState.scanning => text.searchingDevice,
      BleConnectionState.connecting => text.connecting,
      BleConnectionState.awaitingBoot => text.pressBoot,
      BleConnectionState.connected => text.deviceConnected,
      BleConnectionState.disconnected => text.displayNotConnected,
    };
  }
}
