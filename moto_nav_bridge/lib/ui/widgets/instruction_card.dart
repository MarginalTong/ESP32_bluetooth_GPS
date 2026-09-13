import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/navigation_controller.dart';
import '../../models/device_direction.dart';
import '../../models/nav_state.dart';
import '../../services/ble_service.dart';

class InstructionCard extends StatelessWidget {
  const InstructionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    final sent = context.watch<BleService>().lastSent;
    final state = nav.current ?? sent;
    final active = nav.phase == NavPhase.navigating ||
        nav.phase == NavPhase.paused ||
        nav.phase == NavPhase.arrived;
    final colors = Theme.of(context).colorScheme;

    return Container(
      constraints: const BoxConstraints(minHeight: 278),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primaryContainer,
            colors.surfaceContainerHighest,
          ],
        ),
      ),
      child: active && state != null
          ? _ActiveInstruction(state: state)
          : const _WaitingInstruction(),
    );
  }
}

class _ActiveInstruction extends StatelessWidget {
  const _ActiveInstruction({required this.state});

  final NavState state;

  @override
  Widget build(BuildContext context) {
    final distance = state.distanceMeters >= 1000
        ? '${(state.distanceMeters / 1000).toStringAsFixed(1)} km'
        : '${state.distanceMeters} m';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _instruction(state.direction),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const Spacer(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Icon(_icon(state.direction), size: 104),
            const Spacer(),
            Text(
              distance,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.5,
                  ),
            ),
          ],
        ),
        const Spacer(),
        Text(
          state.direction == DeviceDirection.arrived ? '目的地已到达' : '后续路口',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

class _WaitingInstruction extends StatelessWidget {
  const _WaitingInstruction();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.near_me_rounded,
          size: 72,
          color: colors.primary.withValues(alpha: 0.9),
        ),
        const SizedBox(height: 18),
        Text('准备出发', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '连接设备并输入目的地坐标',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

String _instruction(DeviceDirection direction) => switch (direction) {
      DeviceDirection.up => '继续直行',
      DeviceDirection.left => '前方左转',
      DeviceDirection.right => '前方右转',
      DeviceDirection.bearLeft => '靠左行驶',
      DeviceDirection.bearRight => '靠右行驶',
      DeviceDirection.uturn => '前方掉头',
      DeviceDirection.stop => '导航已暂停',
      DeviceDirection.arrived => '已到达',
    };

IconData _icon(DeviceDirection direction) => switch (direction) {
      DeviceDirection.up => Icons.straight_rounded,
      DeviceDirection.left => Icons.turn_left_rounded,
      DeviceDirection.right => Icons.turn_right_rounded,
      DeviceDirection.bearLeft => Icons.turn_slight_left_rounded,
      DeviceDirection.bearRight => Icons.turn_slight_right_rounded,
      DeviceDirection.uturn => Icons.u_turn_left_rounded,
      DeviceDirection.stop => Icons.stop_circle_outlined,
      DeviceDirection.arrived => Icons.sports_score_rounded,
    };
