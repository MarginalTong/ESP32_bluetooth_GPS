import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/navigation_controller.dart';
import '../l10n/app_text.dart';
import '../models/lat_lng.dart';
import '../models/place_result.dart';
import '../models/route_candidate.dart';
import '../services/ble_service.dart';
import 'place_search_page.dart';
import 'widgets/connection_card.dart';
import 'widgets/instruction_card.dart';
import 'widgets/navigation_map.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  PlaceResult? _destination;

  Future<void> _start() async {
    final destination = _destination;
    if (destination == null) return;
    await context
        .read<NavigationController>()
        .startNavigation(destination.location);
  }

  Future<void> _endNavigation() async {
    await context.read<NavigationController>().endNavigation();
    if (mounted) setState(() => _destination = null);
  }

  Future<void> _chooseDestination() async {
    final place = await Navigator.of(context).push<PlaceResult>(
      MaterialPageRoute(builder: (_) => const PlaceSearchPage()),
    );
    if (place != null && mounted) {
      setState(() => _destination = place);
      await context
          .read<NavigationController>()
          .previewDestination(place.location);
    }
  }

  Future<void> _selectMapDestination(LatLng location) async {
    final text = AppText.of(context);
    setState(() {
      _destination = PlaceResult(
        name: text.mapPoint,
        address:
            '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}',
        location: location,
      );
    });
    await context.read<NavigationController>().previewDestination(location);
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    final ble = context.watch<BleService>();
    final navigating = nav.phase == NavPhase.navigating ||
        nav.phase == NavPhase.routing ||
        nav.phase == NavPhase.paused;
    final showInstruction = nav.phase == NavPhase.navigating ||
        nav.phase == NavPhase.paused ||
        nav.phase == NavPhase.arrived;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final idleMapHeight = (screenHeight * 0.42).clamp(320.0, 380.0);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Column(
            children: [
              const _Header(),
              const SizedBox(height: 18),
              Expanded(
                child: ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    const ConnectionCard(),
                    const SizedBox(height: 18),
                    NavigationMap(
                      height: navigating ? 260 : idleMapHeight,
                      origin: nav.origin,
                      destination: nav.destination ?? _destination?.location,
                      destinationName: _destination?.name,
                      routes: nav.routeOptions,
                      selectedRouteIndex: nav.selectedRouteIndex,
                      onRouteSelected: nav.selectRoute,
                      onMapPointSelected:
                          navigating ? null : _selectMapDestination,
                    ),
                    if (showInstruction) ...[
                      const SizedBox(height: 18),
                      const InstructionCard(),
                    ],
                    const SizedBox(height: 18),
                    if (!navigating)
                      _DestinationPanel(
                        destination: _destination,
                        selectedRoute: nav.selectedRoute,
                        previewingRoute: nav.previewingRoute,
                        canStart: ble.state == BleConnectionState.connected,
                        onChoose: _chooseDestination,
                        onStart: _start,
                      )
                    else
                      _NavigationControls(
                        phase: nav.phase,
                        error: nav.error,
                        onPause: nav.pause,
                        onResume: _start,
                        onEnd: _endNavigation,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MOTO NAV',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      letterSpacing: 2.2,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
          ),
        ),
        Icon(
          Icons.near_me_rounded,
          size: 38,
          color: Theme.of(context).colorScheme.primary,
        ),
      ],
    );
  }
}

class _DestinationPanel extends StatelessWidget {
  const _DestinationPanel({
    required this.destination,
    required this.selectedRoute,
    required this.previewingRoute,
    required this.canStart,
    required this.onChoose,
    required this.onStart,
  });

  final PlaceResult? destination;
  final RouteCandidate? selectedRoute;
  final bool previewingRoute;
  final bool canStart;
  final VoidCallback onChoose;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color(0xff6b3414),
            Color(0xff4a2f22),
            Color(0xff2d2521),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                text.destination,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 30),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _RouteEta(
                      seconds: selectedRoute?.expectedTravelTimeSeconds,
                      loading: previewingRoute,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          InkWell(
            onTap: onChoose,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xff171a1f),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: destination == null
                        ? Text(text.searchPlaceAddressBusiness)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                destination!.name,
                                style: Theme.of(context).textTheme.titleSmall,
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
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: canStart && destination != null ? onStart : null,
              icon: const Icon(Icons.navigation_rounded),
              label: Text(
                !canStart
                    ? text.connectNavScreenFirst
                    : destination == null
                        ? text.chooseDestinationFirst
                        : text.startNavigation,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteEta extends StatelessWidget {
  const _RouteEta({
    required this.seconds,
    required this.loading,
  });

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

    final duration = _durationLabel(text, Duration(seconds: seconds));
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

String _durationLabel(AppText text, Duration duration) {
  final minutes = (duration.inSeconds / 60).round().clamp(1, 999);
  if (minutes < 60) {
    return text.durationMinutes(minutes);
  }

  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return text.durationHoursMinutes(hours, remainingMinutes);
}

class _NavigationControls extends StatelessWidget {
  const _NavigationControls({
    required this.phase,
    required this.error,
    required this.onPause,
    required this.onResume,
    required this.onEnd,
  });

  final NavPhase phase;
  final String? error;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onEnd;

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
          child: OutlinedButton.icon(
            onPressed: phase == NavPhase.routing
                ? null
                : phase == NavPhase.paused
                    ? onResume
                    : onPause,
            icon: phase == NavPhase.routing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : phase == NavPhase.paused
                    ? const Icon(Icons.play_arrow_rounded)
                    : const Icon(Icons.pause_rounded),
            label: Text(
              phase == NavPhase.routing
                  ? text.planningRoute
                  : phase == NavPhase.paused
                      ? text.resumeNavigation
                      : text.pauseNavigation,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 54,
          child: FilledButton.tonalIcon(
            onPressed: phase == NavPhase.routing ? null : onEnd,
            icon: const Icon(Icons.stop_circle_rounded),
            label: Text(text.endAndDisconnect),
          ),
        ),
      ],
    );
  }
}
