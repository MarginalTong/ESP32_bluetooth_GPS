import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/navigation_controller.dart';
import '../models/lat_lng.dart';
import '../models/nav_state.dart';
import '../services/ble_service.dart';
import 'widgets/connection_card.dart';
import 'widgets/instruction_card.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();

  @override
  void dispose() {
    _latCtrl.dispose();
    _lngCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _start() async {
    final lat = double.tryParse(_latCtrl.text.trim());
    final lng = double.tryParse(_lngCtrl.text.trim());
    if (lat == null || lng == null) {
      _snack('Enter a valid destination lat/lng');
      return;
    }
    await context
        .read<NavigationController>()
        .startNavigation(LatLng(lat, lng));
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    final ble = context.watch<BleService>();
    final navigating = nav.phase == NavPhase.navigating ||
        nav.phase == NavPhase.routing;

    return Scaffold(
      appBar: AppBar(title: const Text('Moto Nav Bridge')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ConnectionCard(),
          const SizedBox(height: 12),
          _destinationCard(nav, ble),
          const SizedBox(height: 12),
          const InstructionCard(),
          const SizedBox(height: 12),
          _statusLine(nav),
        ],
      ),
      floatingActionButton: navigating
          ? FloatingActionButton.extended(
              onPressed: () => nav.pause(),
              icon: const Icon(Icons.pause),
              label: const Text('Pause (STOP)'),
            )
          : null,
    );
  }

  Widget _destinationCard(NavigationController nav, BleService ble) {
    final canStart = ble.state == BleConnectionState.connected &&
        nav.phase != NavPhase.navigating &&
        nav.phase != NavPhase.routing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Destination',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Latitude'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lngCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Longitude'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: canStart ? _start : null,
                icon: const Icon(Icons.navigation),
                label: Text(canStart
                    ? 'Start navigation'
                    : (ble.state == BleConnectionState.connected
                        ? 'Navigating…'
                        : 'Connect device first')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine(NavigationController nav) {
    final NavState? cur = nav.current;
    final phase = switch (nav.phase) {
      NavPhase.idle => 'Idle',
      NavPhase.routing => 'Fetching route…',
      NavPhase.navigating => 'Navigating',
      NavPhase.arrived => 'Arrived',
      NavPhase.error => 'Error',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Status: $phase'),
        if (cur != null) Text('Current: ${cur.direction.wire} ${cur.distanceMeters}m'),
        if (nav.error != null)
          Text(nav.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}
