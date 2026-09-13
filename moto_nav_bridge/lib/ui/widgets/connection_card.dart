import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/ble_service.dart';

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
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
                      '准备出发',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      ble.lastError ?? _label(ble.state),
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

  String _label(BleConnectionState state) => switch (state) {
        BleConnectionState.idle => '连接设备',
        BleConnectionState.scanning => '正在搜索设备…',
        BleConnectionState.connecting => '正在连接…',
        BleConnectionState.connected => '设备已连接',
        BleConnectionState.disconnected => '连接设备',
      };
}
