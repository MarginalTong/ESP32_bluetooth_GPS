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
                      hasError
                          ? (writeFailed
                              ? text.displayUpdateInterrupted
                              : text.deviceConnectionIssue)
                          : connected
                              ? text.readyToGo
                              : busy
                                  ? text.connectingDisplay
                                  : text.tapToConnect,
                      textAlign: TextAlign.start,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      busy
                          ? _label(context, ble.state)
                          : hasError
                              ? (writeFailed
                                  ? text.reconnectDisplayHint
                                  : text.deviceDetailsHint)
                              : _label(context, ble.state),
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
