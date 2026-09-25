import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_text.dart';
import '../../services/ble_service.dart';

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    final text = AppText.of(context);
    final connected = ble.state == BleConnectionState.connected;
    final busy = ble.state == BleConnectionState.scanning ||
        ble.state == BleConnectionState.connecting;
    final colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surfaceContainerHigh.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: busy ? null : () => connected ? ble.disconnect() : ble.connect(),
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
                      ? const Color(0xff5ee6a8)
                      : busy
                          ? colors.primary
                          : colors.outline,
                  boxShadow: connected
                      ? const [
                          BoxShadow(
                            color: Color(0x665ee6a8),
                            blurRadius: 10,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      text.readyToGo,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      ble.lastError ?? _label(context, ble.state),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: ble.lastError == null
                                ? colors.onSurfaceVariant
                                : colors.error,
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
                  color: connected ? const Color(0xff5ee6a8) : colors.outline,
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
      BleConnectionState.idle => text.connectDevice,
      BleConnectionState.scanning => text.searchingDevice,
      BleConnectionState.connecting => text.connecting,
      BleConnectionState.connected => text.deviceConnected,
      BleConnectionState.disconnected => text.connectDevice,
    };
  }
}
