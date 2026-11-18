import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import '../controllers/account_controller.dart';
import '../controllers/guidance_voice_controller.dart';
import '../controllers/navigation_controller.dart';
import '../controllers/rider_map_controller.dart';
import '../l10n/app_text.dart';
import '../models/lat_lng.dart';
import '../models/place_result.dart';
import '../services/ble_service.dart';
import 'map_settings_page.dart';
import 'navio_theme.dart';
import 'place_search_page.dart';
import 'waypoint_editor_page.dart';
import 'widgets/connection_card.dart';
import 'widgets/destination_panel.dart';
import 'widgets/map_selection_pop.dart';
import 'widgets/glass_panel.dart';
import 'widgets/instruction_card.dart';
import 'widgets/map_control_button.dart';
import 'widgets/navigation_controls.dart';
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
  int _mapSelectionRevision = 0;
  String _mapStyle = 'standard';
  int _settingsRevision = -1;
  final _voice = GuidanceVoiceController();
  // The connection card shrank to its top-left pill: map buttons move up.
  bool _cardCompact = false;

  @override
  void initState() {
    super.initState();
    _voice
      ..addListener(_voiceChanged)
      ..onUnavailable = _voiceUnavailable;
    _loadMapSettings();
  }

  void _voiceChanged() {
    if (mounted) setState(() {});
  }

  void _voiceUnavailable() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppText.of(context).voiceUnavailableOnDevice)),
    );
  }

  Future<void> _loadMapSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getString(MapSettingsPage.styleKey);
    await _voice.reload();
    if (!mounted) return;
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
    _voice.bind(context.read<NavigationController>());
  }

  @override
  void dispose() {
    _voice
      ..removeListener(_voiceChanged)
      ..dispose();
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
      _mapSelectionRevision++;
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
      MaterialPageRoute(
        builder: (_) =>
            WaypointEditorPage(destination: destination, stops: nav.waypoints),
      ),
    );
    if (!mounted || stops == null || !nav.canEditPreferences) return;
    await nav.previewDestination(destination.location, waypoints: stops);
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    final riders = context.watch<RiderMapController?>();
    final ble = context.watch<BleService>();
    final navigating =
        nav.phase == NavPhase.navigating ||
        nav.phase == NavPhase.routing ||
        nav.phase == NavPhase.paused;
    final showInstruction =
        nav.phase == NavPhase.navigating ||
        nav.phase == NavPhase.paused ||
        nav.phase == NavPhase.arrived;
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final landscape = constraints.maxWidth > constraints.maxHeight;
          final darkMapControls = _mapStyle != 'standard';
          final safe = MediaQuery.paddingOf(context);
          final panelWidth = landscape ? 320.0 : constraints.maxWidth - 32;
          // Below the full connection card, or level with its pill.
          final controlsTop = safe.top + (_cardCompact ? 12 : 92);
          final moveDuration = MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : ConnectionCard.resizeDuration;
          // Reserve space for native map attribution and route framing.
          final mapInsets = EdgeInsets.fromLTRB(
            landscape ? panelWidth + 32 : 16,
            safe.top + (landscape ? 8 : 96),
            16,
            safe.bottom + (landscape ? 40 : 230),
          );
          return Theme(
            data: darkMapControls ? NavioTheme.dark() : NavioTheme.light(),
            child: Builder(
              builder: (context) => Stack(
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
                      riders: riders?.viewing == true
                          ? riders!.riders
                          : const [],
                      onRouteSelected: nav.selectRoute,
                      onDiagnostic: nav.recordMapDiagnostic,
                      onMapPointSelected: navigating
                          ? null
                          : _selectMapDestination,
                    ),
                  ),
                  Positioned(
                    top: safe.top + 12,
                    left: 16,
                    child: ConnectionCard(
                      fullWidth: panelWidth,
                      onCompactChanged: (compact) {
                        if (mounted) setState(() => _cardCompact = compact);
                      },
                    ),
                  ),
                  AnimatedPositioned(
                    duration: moveDuration,
                    curve: Curves.easeInOutCubic,
                    top: controlsTop + 0 * 56,
                    right: 16,
                    child: MapControlButton(
                      backgroundKey: const ValueKey(
                        'map-settings-button-background',
                      ),
                      dark: darkMapControls,
                      lightBackground: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.88),
                      icon: Icons.settings_outlined,
                      iconSize: 19,
                      minSize: 44,
                      tooltip: AppText.of(context).mapSettings,
                      onPressed: _openMapSettings,
                    ),
                  ),
                  AnimatedPositioned(
                    duration: moveDuration,
                    curve: Curves.easeInOutCubic,
                    top: controlsTop + 1 * 56,
                    right: 16,
                    child: RiderMapButton(dark: _mapStyle != 'standard'),
                  ),
                  AnimatedPositioned(
                    duration: moveDuration,
                    curve: Curves.easeInOutCubic,
                    top: controlsTop + 2 * 56,
                    right: 16,
                    child: MapControlButton(
                      dark: darkMapControls,
                      icon: _voice.enabled
                          ? Icons.volume_up_rounded
                          : Icons.volume_off_rounded,
                      lightIconColor: NavioColors.mapControlIconLight,
                      tooltip: AppText.of(
                        context,
                      ).guidanceVoiceToggle(_voice.enabled),
                      onPressed: _voice.toggle,
                    ),
                  ),
                  Positioned(
                    left: 16,
                    bottom: safe.bottom + 24,
                    width: panelWidth,
                    child: MapSelectionPop(
                      selectionRevision: _mapSelectionRevision,
                      enabled: !navigating,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              (constraints.maxHeight - safe.vertical - 128)
                                  .clamp(80, 600),
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (navigating && nav.waypoints.isNotEmpty) ...[
                                WaypointProgressBanner(nav: nav),
                                const SizedBox(height: 8),
                              ],
                              if (showInstruction) ...[
                                const InstructionCard(),
                                const SizedBox(height: 10),
                              ],
                              if (!navigating)
                                DestinationPanel(
                                  destination: _destination,
                                  selectedRoute: nav.selectedRoute,
                                  previewingRoute: nav.previewingRoute,
                                  canStart:
                                      ble.state == BleConnectionState.connected,
                                  waypointCount: nav.waypoints.length,
                                  onEditWaypoints: _editWaypoints,
                                  onChoose: _chooseDestination,
                                  onStart: _start,
                                )
                              else
                                GlassPanel(
                                  padding: const EdgeInsets.all(12),
                                  child: NavigationControls(
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
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
