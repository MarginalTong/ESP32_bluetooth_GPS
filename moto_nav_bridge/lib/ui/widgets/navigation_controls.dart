import 'package:flutter/material.dart';

import '../../controllers/navigation_controller.dart';
import '../../l10n/app_text.dart';
import '../navio_theme.dart';
import 'glass_panel.dart';

/// Which stop comes next during a trip with waypoints.
class WaypointProgressBanner extends StatelessWidget {
  const WaypointProgressBanner({super.key, required this.nav});

  final NavigationController nav;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final done = nav.completedWaypoints;
    final total = nav.waypoints.length;
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Text(
        done < total
            ? text.nextStopProgress(nav.waypoints[done].name, done + 1, total)
            : text.allStopsVisitedContinuing,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// End the trip, optionally also disconnecting the display.
class NavigationControls extends StatelessWidget {
  const NavigationControls({
    super.key,
    required this.phase,
    required this.error,
    required this.onEnd,
    required this.onEndAndDisconnect,
  });

  final NavPhase phase;
  final String? error;
  final VoidCallback onEnd;
  final VoidCallback onEndAndDisconnect;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          height: 54,
          child: TextButton.icon(
            onPressed: phase == NavPhase.routing ? null : onEnd,
            icon: const Icon(Icons.stop_circle_rounded),
            label: Text(text.endNavigation),
          ),
        ),
        const Divider(height: 12, color: NavioColors.panelDivider),
        SizedBox(
          height: 54,
          child: TextButton.icon(
            onPressed: phase == NavPhase.routing ? null : onEndAndDisconnect,
            icon: const Icon(Icons.bluetooth_disabled_rounded),
            label: Text(text.endAndDisconnect),
          ),
        ),
      ],
    );
  }
}
