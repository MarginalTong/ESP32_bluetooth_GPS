import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/navigation_controller.dart';
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

  Future<void> _chooseDestination() async {
    final place = await Navigator.of(context).push<PlaceResult>(
      MaterialPageRoute(builder: (_) => const PlaceSearchPage()),
    );
    if (place != null && mounted) setState(() => _destination = place);
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    final ble = context.watch<BleService>();
    final navigating =
        nav.phase == NavPhase.navigating || nav.phase == NavPhase.routing;

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
              sliver: SliverList.list(
                children: [
                  _Header(phase: nav.phase),
                  const SizedBox(height: 18),
                  const ConnectionCard(),
                  const SizedBox(height: 18),
                  NavigationMap(
                    origin: nav.origin,
                    destination: nav.destination ?? _destination?.location,
                    destinationName: _destination?.name,
                  ),
                  const SizedBox(height: 18),
                  const InstructionCard(),
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
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.phase});
  final NavPhase phase;

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
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      letterSpacing: 2.2,
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 3),
              Text(
                _phaseLabel(phase),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
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
            Icons.two_wheeler_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  String _phaseLabel(NavPhase phase) => switch (phase) {
        NavPhase.idle => '导航控制台',
        NavPhase.routing => '正在规划路线',
        NavPhase.navigating => '导航进行中',
        NavPhase.arrived => '顺利抵达',
        NavPhase.error => '需要处理',
      };
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
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(22),
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
  });

  final NavPhase phase;
  final String? error;
  final VoidCallback onPause;

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
            onPressed: phase == NavPhase.routing ? null : onPause,
            icon: phase == NavPhase.routing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.pause_rounded),
            label: Text(phase == NavPhase.routing ? '路线规划中…' : '暂停导航'),
          ),
        ),
      ],
    );
  }
}
