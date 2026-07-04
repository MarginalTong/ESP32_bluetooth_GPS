import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/ble_constants.dart';
import '../../services/ble_service.dart';

/// Shows BLE connection status and a connect/disconnect button.
class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    final connected = ble.state == BleConnectionState.connected;
    final busy = ble.state == BleConnectionState.scanning ||
        ble.state == BleConnectionState.connecting;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: connected ? Colors.greenAccent : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  BleConstants.deviceName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(_label(ble.state)),
              ],
            ),
            if (ble.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                ble.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => connected ? ble.disconnect() : ble.connect(),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(connected ? Icons.link_off : Icons.link),
                label: Text(connected ? 'Disconnect' : 'Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _label(BleConnectionState s) => switch (s) {
        BleConnectionState.idle => 'Idle',
        BleConnectionState.scanning => 'Scanning…',
        BleConnectionState.connecting => 'Connecting…',
        BleConnectionState.connected => 'Connected',
        BleConnectionState.disconnected => 'Disconnected',
      };
}
