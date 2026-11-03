import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/navigation_controller.dart';
import '../../l10n/app_text.dart';
import '../../models/place_result.dart';
import '../../models/route_candidate.dart';
import '../route_preferences_page.dart';
import 'glass_panel.dart';

/// Destination search, route ETA, stops and Start, shown before a trip.
class DestinationPanel extends StatelessWidget {
  const DestinationPanel({
    super.key,
    required this.destination,
    required this.selectedRoute,
    required this.previewingRoute,
    required this.canStart,
    required this.onChoose,
    required this.onStart,
    required this.waypointCount,
    required this.onEditWaypoints,
  });

  final PlaceResult? destination;
  final RouteCandidate? selectedRoute;
  final bool previewingRoute;
  final bool canStart;
  final VoidCallback onChoose;
  final VoidCallback onStart;
  final int waypointCount;
  final VoidCallback onEditWaypoints;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => RoutePreferencesPage(
                    nav: context.read<NavigationController>(),
                  ),
                ),
              ),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: Text(text.routePreferences),
            ),
          ),
          if (selectedRoute?.expectedTravelTimeSeconds != null ||
              previewingRoute)
            Align(
              alignment: Alignment.centerRight,
              child: RouteEta(
                seconds: selectedRoute?.expectedTravelTimeSeconds,
                loading: previewingRoute,
              ),
            ),
          InkWell(
            onTap: onChoose,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: destination == null
                          ? Text(
                              text.searchPlaceAddressBusiness,
                              style: Theme.of(context).textTheme.titleMedium,
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  destination!.name,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  destination!.address,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (destination != null)
            TextButton.icon(
              onPressed: previewingRoute ? null : onEditWaypoints,
              icon: const Icon(Icons.add_location_alt_outlined, size: 18),
              label: Text(text.editStops(waypointCount)),
            ),
          if (destination == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
              child: Text(
                !canStart
                    ? text.connectNavScreenFirst
                    : text.chooseDestinationFirst,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: canStart && destination != null && !previewingRoute
                    ? onStart
                    : null,
                icon: const Icon(Icons.navigation_rounded),
                label: Text(
                  !canStart
                      ? text.connectNavScreenFirst
                      : destination == null
                      ? text.chooseDestinationFirst
                      : text.startNavigation,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class RouteEta extends StatelessWidget {
  const RouteEta({super.key, required this.seconds, required this.loading});

  final int? seconds;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final seconds = this.seconds;
    if (loading) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text.planningRouteShort,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    }

    if (seconds == null) return const SizedBox.shrink();

    final duration = durationLabel(text, Duration(seconds: seconds));
    final arrival = TimeOfDay.fromDateTime(
      DateTime.now().add(Duration(seconds: seconds)),
    ).format(context);

    return Text(
      text.etaSummary(duration, arrival),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

String durationLabel(AppText text, Duration duration) {
  final minutes = (duration.inSeconds / 60).round().clamp(1, 999);
  if (minutes < 60) {
    return text.durationMinutes(minutes);
  }

  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return text.durationHoursMinutes(hours, remainingMinutes);
}
