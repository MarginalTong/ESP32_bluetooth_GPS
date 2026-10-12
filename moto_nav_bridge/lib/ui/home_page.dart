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
import 'widgets/glass_panel.dart';
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

  Future<void> _endNavigation({required bool disconnectDevice}) async {
    await context.read<NavigationController>().endNavigation(
          disconnectDevice: disconnectDevice,
        );
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
    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        final landscape = constraints.maxWidth > constraints.maxHeight;
        final safe = MediaQuery.paddingOf(context);
        final panelWidth = landscape ? 320.0 : constraints.maxWidth - 32;
        // Reserve space for native map attribution and route framing.
        final mapInsets = EdgeInsets.fromLTRB(
          landscape ? panelWidth + 32 : 16,
          safe.top + (landscape ? 8 : 96),
          16,
          safe.bottom + (landscape ? 40 : 300),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: NavigationMap(
                height: constraints.maxHeight,
                borderRadius: 0,
                contentPadding: mapInsets,
                origin: nav.origin,
                destination: nav.destination ?? _destination?.location,
                destinationName: _destination?.name,
                routes: nav.routeOptions,
                selectedRouteIndex: nav.selectedRouteIndex,
                onRouteSelected: nav.selectRoute,
                onMapPointSelected: navigating ? null : _selectMapDestination,
              ),
            ),
            Positioned(
              top: safe.top + 12,
              left: 16,
              width: panelWidth,
              child: const ConnectionCard(),
            ),
            Positioned(
              left: 16,
              bottom: safe.bottom + 36,
              width: panelWidth,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (constraints.maxHeight - safe.vertical - 128)
                      .clamp(80, 600),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showInstruction) ...[
                        const InstructionCard(),
                        const SizedBox(height: 10),
                      ],
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
                        GlassPanel(
                          padding: const EdgeInsets.all(12),
                          child: _NavigationControls(
                            phase: nav.phase,
                            error: nav.error,
                            onEnd: () =>
                                _endNavigation(disconnectDevice: false),
                            onEndAndDisconnect: () =>
                                _endNavigation(disconnectDevice: true),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      }),
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
    return GlassPanel(
      padding: const EdgeInsets.all(16),
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
              decoration: const ShapeDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x38ffffff), Color(0x10ffffff)],
                ),
                shape: GlassShape(
                    borderRadius: BorderRadius.all(Radius.circular(14))),
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
          child: OutlinedButton.icon(
            onPressed: phase == NavPhase.routing ? null : onEnd,
            icon: const Icon(Icons.stop_circle_rounded),
            label: Text(text.endNavigation),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 54,
          child: FilledButton.tonalIcon(
            onPressed: phase == NavPhase.routing ? null : onEndAndDisconnect,
            icon: const Icon(Icons.bluetooth_disabled_rounded),
            label: Text(text.endAndDisconnect),
          ),
        ),
      ],
    );
  }
}
