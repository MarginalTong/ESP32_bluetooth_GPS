import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/navigation_controller.dart';
import '../models/lat_lng.dart';
import '../models/place_result.dart';
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
    if (place != null && mounted) setState(() => _destination = place);
  }

  void _selectMapDestination(LatLng location) {
    setState(() {
      _destination = PlaceResult(
        name: '地图选点',
        address:
            '${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}',
        location: location,
      );
    });
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
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(
            Icons.near_me_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

class _DestinationPanel extends StatelessWidget {
  const _DestinationPanel({
    required this.destination,
    required this.canStart,
    required this.onChoose,
    required this.onStart,
  });

  final PlaceResult? destination;
  final bool canStart;
  final VoidCallback onChoose;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
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
          Text('目的地', style: Theme.of(context).textTheme.titleMedium),
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
                        ? const Text('搜索地点、地址或商家')
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
                    ? '请先连接导航屏'
                    : destination == null
                        ? '请先选择目的地'
                        : '开始导航',
              ),
            ),
          ),
        ],
      ),
    );
  }
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
                  ? '路线规划中…'
                  : phase == NavPhase.paused
                      ? '继续导航'
                      : '暂停导航',
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 54,
          child: FilledButton.tonalIcon(
            onPressed: phase == NavPhase.routing ? null : onEnd,
            icon: const Icon(Icons.stop_circle_rounded),
            label: const Text('结束导航并断开'),
          ),
        ),
      ],
    );
  }
}
