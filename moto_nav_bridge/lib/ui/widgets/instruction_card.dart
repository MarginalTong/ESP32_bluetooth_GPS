import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/navigation_controller.dart';
import '../../l10n/app_text.dart';
import 'glass_panel.dart';
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
    return GlassPanel(
      padding: const EdgeInsets.all(16),
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
    final text = AppText.of(context);
    final distance = state.distanceMeters >= 1000
        ? '${(state.distanceMeters / 1000).toStringAsFixed(1)} km'
        : '${state.distanceMeters} m';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          state.rerouting
              ? text.rerouting
              : _instruction(text, state.direction),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Icon(state.rerouting ? Icons.sync : _icon(state.direction),
                size: 48),
            const SizedBox(width: 16),
            Flexible(
                child: Text(
              state.rerouting ? '…' : distance,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1.5,
                  ),
            )),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          state.rerouting
              ? text.rerouting
              : state.direction == DeviceDirection.arrived
                  ? text.destinationReached
                  : text.nextTurn,
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
    final text = AppText.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.near_me_rounded,
          size: 72,
          color: colors.primary.withValues(alpha: 0.9),
        ),
        const SizedBox(height: 18),
        Text(text.readyToGo, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          text.connectDeviceAndEnterDestination,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

String _instruction(AppText text, DeviceDirection direction) =>
    switch (direction) {
      DeviceDirection.up => text.keepStraight,
      DeviceDirection.left => text.turnLeftAhead,
      DeviceDirection.right => text.turnRightAhead,
      DeviceDirection.bearLeft => text.bearLeft,
      DeviceDirection.bearRight => text.bearRight,
      DeviceDirection.uturn => text.uTurnAhead,
      DeviceDirection.stop => text.navigationPaused,
      DeviceDirection.arrived => text.arrived,
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
