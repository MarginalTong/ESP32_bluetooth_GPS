import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device_direction.dart';
import '../../services/ble_service.dart';

/// Mirrors what the ESP32 is currently showing: the direction icon, the
/// distance, and the last payload actually written over BLE.
class InstructionCard extends StatelessWidget {
  const InstructionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    final state = ble.lastSent;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device instruction',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (state == null)
              const Text('No instruction sent yet.')
            else
              Row(
                children: [
                  Icon(_icon(state.direction), size: 48),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(state.direction.wire,
                          style: Theme.of(context).textTheme.headlineSmall),
                      Text('${state.distanceMeters} m'),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    state.toWire(),
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  IconData _icon(DeviceDirection d) => switch (d) {
        DeviceDirection.up => Icons.arrow_upward,
        DeviceDirection.left => Icons.turn_left,
        DeviceDirection.right => Icons.turn_right,
        DeviceDirection.bearLeft => Icons.turn_slight_left,
        DeviceDirection.bearRight => Icons.turn_slight_right,
        DeviceDirection.uturn => Icons.u_turn_left,
        DeviceDirection.stop => Icons.stop_circle,
        DeviceDirection.arrived => Icons.flag,
      };
}
