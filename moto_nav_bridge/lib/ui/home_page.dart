import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import '../controllers/navigation_controller.dart';
import '../controllers/account_controller.dart';
import '../controllers/rider_map_controller.dart';
import '../l10n/app_text.dart';
import '../models/lat_lng.dart';
import '../models/device_direction.dart';
import '../models/place_result.dart';
import '../models/route_candidate.dart';
import '../services/ble_service.dart';
import '../services/guidance/voice_guidance_planner.dart';
import '../services/navigation_voice.dart';
import 'place_search_page.dart';
import 'map_settings_page.dart';
import 'navio_theme.dart';
import 'route_preferences_page.dart';
import 'waypoint_editor_page.dart';
import 'widgets/connection_card.dart';
import 'widgets/glass_panel.dart';
import 'widgets/instruction_card.dart';
import 'widgets/navigation_map.dart';
import 'widgets/rider_map_button.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onMapStyleChanged});

  final ValueChanged<String>? onMapStyleChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  PlaceResult? _destination;
  String _mapStyle = 'standard';
  int _settingsRevision = -1;
  final _guidance = VoiceGuidancePlanner();
  NavigationController? _voiceNav;
  bool _voiceEnabled = false;
  // Native speech reports when a navigation announcement starts and ends.
  static const _voiceEvents = MethodChannel('moto_nav_bridge/voice');
  bool _navigationSpeechSpeaking = false;
  @override
  void initState() {
    super.initState();
    _loadMapSettings();
    _voiceEvents.setMethodCallHandler((call) async {
      if (!mounted || call.method != 'speechState') return;
      final state = call.arguments as String;
      if (state == 'navigationSpeechStarted') _navigationSpeechSpeaking = true;
      if (state == 'navigationSpeechEnded') _navigationSpeechSpeaking = false;
    });
  }

  Future<void> _loadMapSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getString(MapSettingsPage.styleKey);
    setState(() {
      _mapStyle =
          {'standard', 'standard_dark', 'hybrid', 'satellite'}.contains(saved)
              ? saved!
              : 'standard';
    });
    widget.onMapStyleChanged?.call(_mapStyle);
  }

  Future<void> _openMapSettings() async {
    final place = await Navigator.of(context).push<PlaceResult>(
      MaterialPageRoute(builder: (_) => const MapSettingsPage()),
    );
    if (!mounted) return;
    await _loadMapSettings();
    if (!mounted || place == null) return;
    final nav = context.read<NavigationController>();
    if (nav.phase == NavPhase.navigating || nav.phase == NavPhase.paused) {
      return;
    }
    setState(() => _destination = place);
    await nav.previewDestination(place.location, waypoints: nav.waypoints);
  }

  void _toggleGuidance() {
    setState(() => _voiceEnabled = !_voiceEnabled);
    _guidance.reset();
    if (_voiceEnabled) {
      _announce();
    } else {
      _silence();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revision = context.watch<AccountController?>()?.settingsRevision ?? 0;
    if (_settingsRevision != revision) {
      if (_settingsRevision >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadMapSettings();
        });
      }
      _settingsRevision = revision;
    }
    final nav = context.read<NavigationController>();
    if (identical(nav, _voiceNav)) return;
    _voiceNav?.removeListener(_announce);
    _voiceNav = nav;
    nav.addListener(_announce);
  }

  Future<void> _silence() async {
    try {
      await NavigationVoice.stop();
    } catch (_) {/* Optional native audio. */}
  }

  void _announce() {
    if (!mounted || !_voiceEnabled) return;
    final nav = _voiceNav!;
    final state = nav.current;
    final route = nav.selectedRoute;
    // Rerouting keeps speaking: the planner announces it once.
    if (state == null ||
        route == null ||
        (state.direction == DeviceDirection.stop && !state.rerouting) ||
        (nav.phase != NavPhase.navigating && nav.phase != NavPhase.arrived)) {
      _silence();
      return;
    }
    final fix = nav.voiceFix;
    final utterance = _guidance.next(
        GuidanceInput(
          route: route,
          steps: route.steps,
          stepIndex: nav.voiceStepIndex,
          state: state,
          now: DateTime.now(),
          reliable: nav.voiceGuidanceReliable,
          speedMps: fix?.speed,
          accuracyMeters: fix?.accuracy,
          rerouteFailed: nav.rerouteFailed,
          speaking: _navigationSpeechSpeaking,
        ),
        english: AppText.of(context).isEnglish);
    if (utterance != null) _speak(utterance.text);
  }

  Future<void> _speak(String message) async {
    try {
      await NavigationVoice.speak(message,
          english: AppText.of(context).isEnglish);
    } catch (_) {
      if (!mounted) return;
      setState(() => _voiceEnabled = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppText.of(context).isEnglish
              ? 'Voice is unavailable on this device.'
              : '此设备暂不支持语音播报。')));
    }
  }

  @override
  void dispose() {
    _voiceEvents.setMethodCallHandler(null);
    _voiceNav?.removeListener(_announce);
    _silence();
    super.dispose();
  }

  Future<void> _start() async {
    final destination = _destination;
    if (destination == null) return;
    final nav = context.read<NavigationController>();
    await nav.startNavigation(destination.location, waypoints: nav.waypoints);
  }

  Future<void> _endNavigation({required bool disconnectDevice}) async {
    await context.read<NavigationController>().endNavigation(
          disconnectDevice: disconnectDevice,
        );
    if (mounted) setState(() => _destination = null);
  }

  Future<void> _chooseDestination() async {
    var startNow = false;
    final place = await Navigator.of(context).push<PlaceResult>(
      MaterialPageRoute(
        builder: (_) => PlaceSearchPage(onSavedPlace: (_) => startNow = true),
      ),
    );
    if (place != null && mounted) {
      setState(() => _destination = place);
      final nav = context.read<NavigationController>();
      // Without a connected display the trip cannot start: show the route.
      if (startNow &&
          context.read<BleService>().state == BleConnectionState.connected) {
        await nav.startNavigation(place.location, waypoints: nav.waypoints);
      } else {
        await nav.previewDestination(place.location, waypoints: nav.waypoints);
      }
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
    final nav = context.read<NavigationController>();
    await nav.previewDestination(location, waypoints: nav.waypoints);
  }

  Future<void> _editWaypoints() async {
    final destination = _destination;
    final nav = context.read<NavigationController>();
    if (destination == null || !nav.canEditPreferences) return;
    final stops = await Navigator.of(context).push<List<PlaceResult>>(
        MaterialPageRoute(builder: (_) => WaypointEditorPage(
            destination: destination, stops: nav.waypoints)));
    if (!mounted || stops == null || !nav.canEditPreferences) return;
    await nav.previewDestination(destination.location, waypoints: stops);
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    final riders = context.watch<RiderMapController?>();
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
        final darkMapControls = _mapStyle != 'standard';
        final safe = MediaQuery.paddingOf(context);
        final panelWidth = landscape ? 320.0 : constraints.maxWidth - 32;
        // Reserve space for native map attribution and route framing.
        final mapInsets = EdgeInsets.fromLTRB(
          landscape ? panelWidth + 32 : 16,
          safe.top + (landscape ? 8 : 96),
          16,
          safe.bottom + (landscape ? 40 : 230),
        );
        return Theme(
          data: darkMapControls ? NavioTheme.dark() : NavioTheme.light(),
          child: Builder(builder: (context) => Stack(
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
                mapStyle: _mapStyle,
                riders: riders?.viewing == true ? riders!.riders : const [],
                onRouteSelected: nav.selectRoute,
                onDiagnostic: nav.recordMapDiagnostic,
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
              top: safe.top + 92,
              right: 16,
              child: Material(
                key: const ValueKey('map-settings-button-background'),
                color: darkMapControls
                    ? const Color(0xff121820)
                    : Theme.of(context)
                        .colorScheme
                        .surface
                        .withValues(alpha: 0.88),
                shape: const CircleBorder(),
                elevation: 1,
                child: IconButton(
                  onPressed: _openMapSettings,
                  tooltip:
                      AppText.of(context).isEnglish ? 'Map settings' : '地图设置',
                  icon: Icon(Icons.settings_outlined,
                      size: 19, color: darkMapControls ? Colors.white : null),
                  constraints:
                      const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
              ),
            ),
            Positioned(top: safe.top + 148, right: 16,
                child: RiderMapButton(dark: _mapStyle != 'standard')),
            Positioned(
              top: safe.top + 204,
              right: 16,
              child: Material(
                color: darkMapControls ? const Color(0xff121820) : const Color(0xf5ffffff),
                shape: const CircleBorder(),
                elevation: 1,
                child: IconButton(
                  tooltip: AppText.of(context).isEnglish
                      ? (_voiceEnabled ? 'Turn off guidance voice' : 'Turn on guidance voice')
                      : (_voiceEnabled ? '关闭导航播报' : '开启导航播报'),
                  icon: Icon(_voiceEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                      size: 20, color: darkMapControls ? Colors.white : const Color(0xff3a3a3c)),
                  onPressed: _toggleGuidance,
                ),
              ),
            ),
            Positioned(
              left: 16,
              bottom: safe.bottom + 24,
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
                      if (navigating && nav.waypoints.isNotEmpty) ...[
                        GlassPanel(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Text(nav.completedWaypoints < nav.waypoints.length
                              ? '${AppText.of(context).isEnglish ? "Next stop" : "下一途经点"}: ${nav.waypoints[nav.completedWaypoints].name} (${nav.completedWaypoints + 1}/${nav.waypoints.length})'
                              : (AppText.of(context).isEnglish ? 'All stops visited · continuing to destination' : '途经点已全部经过 · 继续前往终点'),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(height: 8),
                      ],
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
                          waypointCount: nav.waypoints.length,
                          onEditWaypoints: _editWaypoints,
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
        )),
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
                          nav: context.read<NavigationController>()))),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: Text(text.isEnglish ? 'Route preferences' : '路线偏好'),
            ),
          ),
          if (selectedRoute?.expectedTravelTimeSeconds != null ||
              previewingRoute)
            Align(
              alignment: Alignment.centerRight,
              child: _RouteEta(
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: destination == null
                          ? Text(text.searchPlaceAddressBusiness,
                              style: Theme.of(context).textTheme.titleMedium)
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  destination!.name,
                                  style: Theme.of(context).textTheme.titleMedium,
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
          if (destination != null) TextButton.icon(
            onPressed: previewingRoute ? null : onEditWaypoints,
            icon: const Icon(Icons.add_location_alt_outlined, size: 18),
            label: Text(text.isEnglish
                ? (waypointCount == 0 ? 'Add stops' : 'Edit stops ($waypointCount)')
                : (waypointCount == 0 ? '添加途经点' : '编辑途经点（$waypointCount）')),
          ),
          if (destination == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
              child: Text(!canStart ? text.connectNavScreenFirst : text.chooseDestinationFirst,
                  style: Theme.of(context).textTheme.bodySmall),
            )
          else SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: canStart && destination != null && !previewingRoute ? onStart : null,
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
          child: TextButton.icon(
            onPressed: phase == NavPhase.routing ? null : onEnd,
            icon: const Icon(Icons.stop_circle_rounded),
            label: Text(text.endNavigation),
          ),
        ),
        const Divider(height: 12, color: Color(0x33708090)),
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
