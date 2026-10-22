import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/nearby_places.dart';
import '../services/apple_maps_service.dart';
import 'package:provider/provider.dart';

import '../controllers/navigation_controller.dart';
import '../l10n/app_text.dart';
import '../models/lat_lng.dart';
import '../models/device_direction.dart';
import '../models/place_result.dart';
import '../models/route_candidate.dart';
import '../services/ble_service.dart';
import '../services/navigation_voice.dart';
import '../services/spoken_place_label.dart';
import '../services/saved_places.dart';
import '../services/voice_navigation_query.dart';
import '../services/voice_trip_access.dart';
import 'place_search_page.dart';
import 'map_settings_page.dart';
import 'route_preferences_page.dart';
import 'voice_test_page.dart';
import 'voice_trip_access_prompt.dart';
import 'widgets/connection_card.dart';
import 'widgets/glass_panel.dart';
import 'widgets/instruction_card.dart';
import 'widgets/navigation_map.dart';

enum _AgentAction { open, guidance }

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onMapStyleChanged});

  final ValueChanged<String>? onMapStyleChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  PlaceResult? _destination;
  int _routeAnimationId = 0;
  String _mapStyle = 'standard';
  bool _showTraffic = false;
  final _voice = NavigationVoice();
  NavigationController? _voiceNav;
  bool _voiceEnabled = false;
  static const _wakeChannel = MethodChannel('moto_nav_bridge/voice');
  static const _wakeConsentKey = 'voice_wake_auto_consent_v1';
  bool _wakeEnabled = false;
  bool _wakeDialogue = false;
  bool _wakeBlocked = false;
  bool _navigationSpeechSpeaking = false;
  String _wakeState = 'off';
  int _wakeGeneration = 0;
  Route<void>? _wakeRoute;

  bool get _inTrip =>
      _voiceNav != null &&
      {NavPhase.navigating, NavPhase.paused}.contains(_voiceNav!.phase);

  String _voiceRouteSnapshot(bool en) {
    final nav = _voiceNav;
    if (nav == null || nav.phase != NavPhase.navigating) {
      return 'navigation=inactive';
    }
    final instruction = nav.voiceGuidanceReliable && nav.current != null
        ? NavigationVoice.instruction(nav.current!, english: en)
        : null;
    final remaining = nav.voiceRemainingSeconds;
    final route = nav.selectedRoute;
    final snapshot = [
      'navigation=active',
      'instruction=${instruction ?? "unavailable_or_stale"}',
      'remaining_seconds=${remaining ?? "unavailable"}',
      'route_name=${route?.name ?? "unavailable"}',
      'route_total_metres=${route?.distanceMeters ?? "unavailable"}',
    ].join('; ').replaceAll(RegExp(r'[\x00-\x1F]'), ' ');
    return snapshot.length > 500 ? snapshot.substring(0, 500) : snapshot;
  }

  Future<List<String>> _voiceSavedSlots() async =>
      (await SavedPlaces().load()).keys.toList();

  Future<String> _confirmSavedVoiceDestination(
      String slot,
      bool en,
      bool Function() isCurrent,
      Future<String> Function(String, String) ask) async {
    final place = (await SavedPlaces().load())[slot];
    if (place == null || !mounted || !isCurrent()) {
      return en
          ? 'That saved place is unavailable. Your route has not changed.'
          : '没有找到这个已保存地点，路线没有更改。';
    }
    return _confirmVoiceDestination('', en, isCurrent, ask,
        suppliedPlaces: [place]);
  }

  @override
  void initState() {
    super.initState();
    _loadMapSettings();
    WidgetsBinding.instance.addObserver(this);
    _wakeChannel.setMethodCallHandler((call) async {
      if (!mounted || call.method != 'wakeState') return;
      final state = call.arguments as String;
      if (state == 'navigationSpeechStarted') {
        _navigationSpeechSpeaking = true;
        return;
      }
      if (state == 'navigationSpeechEnded') {
        _navigationSpeechSpeaking = false;
        return;
      }
      if (state == 'wake' && _wakeEnabled && _inTrip && !_wakeDialogue) {
        await _openWakeDialogue();
      } else if (state == 'speechEnded') {
        if (_wakeEnabled && _inTrip && !_wakeDialogue) await _armWake();
      } else if (state.startsWith('resume_') && _wakeEnabled && _inTrip) {
        if (!_wakeBlocked) return;
        _voiceNav?.recordAgentDiagnostic('wake_$state');
        _wakeBlocked = false;
        if (!_wakeDialogue) await _armWake();
      } else if (_wakeEnabled) {
        if (state == 'unavailable') {
          _markWakeUnavailable();
          return;
        }
        if (state.startsWith('paused_')) {
          _wakeBlocked = true;
          _voiceNav?.recordAgentDiagnostic('wake_$state');
          if (state == 'paused_route') _recoverWakeAfterRouteChange();
        } else if (state.startsWith('listening_')) {
          _voiceNav?.recordAgentDiagnostic('wake_$state');
        }
        setState(() => _wakeState = state);
      }
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
      _showTraffic = prefs.getBool(MapSettingsPage.trafficKey) ?? false;
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
    await nav.previewDestination(place.location);
  }

  Future<void> _recoverWakeAfterRouteChange() async {
    final generation = _wakeGeneration;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted ||
        !_wakeEnabled ||
        !_inTrip ||
        _wakeDialogue ||
        generation != _wakeGeneration ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _wakeBlocked = false;
    _voiceNav?.recordAgentDiagnostic('wake_resume_route');
    await _armWake();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _wakeEnabled &&
        _inTrip &&
        _wakeBlocked) {
      _wakeBlocked = false;
      if (!_wakeDialogue) _armWake();
    }
  }

  Future<void> _armWake() async {
    if (!mounted ||
        !_wakeEnabled ||
        !_inTrip ||
        _wakeDialogue ||
        _wakeBlocked) {
      return;
    }
    final id = ++_wakeGeneration;
    try {
      final started = await _wakeChannel.invokeMethod<bool>('startWake', {
        'language': AppText.of(context).isEnglish ? 'en-AU' : 'zh-CN',
      });
      if (mounted && id == _wakeGeneration) {
        if (started != true) {
          _markWakeUnavailable();
        }
      }
    } catch (_) {
      if (mounted && id == _wakeGeneration) {
        _markWakeUnavailable();
      }
    }
  }

  void _markWakeUnavailable() {
    if (!mounted) return;
    setState(() {
      _wakeBlocked = true;
      _wakeState = 'unavailable';
    });
    _voiceNav?.recordAgentDiagnostic('wake_unavailable');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppText.of(context).isEnglish
            ? 'Voice wake is unavailable. Check Microphone and Speech Recognition permissions and on-device language support.'
            : '语音唤醒暂不可用。请检查麦克风、语音识别权限和本机语言支持。')));
  }

  Future<bool> _wakeConsentForTrip() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_wakeConsentKey) == true) return true;
    if (!mounted) return false;
    final en = AppText.of(context).isEnglish;
    final consent = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(
                    en ? 'Enable voice wake during navigation?' : '导航时启用语音唤醒？'),
                content: Text(en
                    ? 'After you start navigation, the phone listens on-device for “Hey Moto” or “导航” while the App is in the foreground. Once woken, your command recording is sent to Gemini. You can still start navigation without voice wake. Set this up while parked.'
                    : '开始导航后，App 在前台使用手机本机识别“导航”或“Hey Moto”。唤醒后，你的指令录音会发送给 Gemini。不启用也能正常导航。请停车设置。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(en ? 'Navigate without wake' : '仅开始导航')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(en ? 'Enable automatically' : '默认开启唤醒'))
                ]));
    if (!mounted || consent != true) return false;
    return prefs.setBool(_wakeConsentKey, true);
  }

  Future<void> _enableWakeForTrip() async {
    if (!mounted || !_inTrip) return;
    setState(() {
      _wakeEnabled = true;
      _wakeBlocked = false;
      _wakeState = 'starting';
    });
    _voiceNav?.recordAgentDiagnostic('wake_started');
    await _armWake();
  }

  Future<void> _openWakeDialogue() async {
    _wakeDialogue = true;
    setState(() => _wakeState = 'dialogue');
    final route = MaterialPageRoute<void>(
        builder: (_) => VoiceTestPage(
              wakeSession: true,
              routeSnapshot: _voiceRouteSnapshot,
              savedSlots: _voiceSavedSlots,
              confirmSavedDestinationByVoice: _confirmSavedVoiceDestination,
              confirmDestinationByVoice: _confirmVoiceDestination,
              findNearbyByVoice: _findNearbyByVoice,
              answerQuery: (text, en) => answerVoiceQuery(text,
                  english: en,
                  state: _voiceNav!.current,
                  reliable: _voiceNav!.voiceGuidanceReliable,
                  navigationActive: _voiceNav!.phase == NavPhase.navigating,
                  remainingSeconds: _voiceNav!.voiceRemainingSeconds),
              shouldDeferNonUrgentReply: () => _navigationSpeechSpeaking,
            ));
    _wakeRoute = route;
    await Navigator.of(context).push(route);
    _wakeRoute = null;
    _wakeDialogue = false;
    // Let the departing page release its audio resources before rearming.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (mounted) await _armWake();
  }

  void _syncWakeTrip() {
    if (_inTrip || !_wakeEnabled) return;
    _wakeGeneration++;
    _wakeEnabled = false;
    _wakeState = 'off';
    _wakeChannel.invokeMethod<void>('stopWake').catchError((_) {});
    if (_wakeRoute?.isActive == true) {
      Navigator.of(context).removeRoute(_wakeRoute!);
    }
  }

  Future<void> _openAgent() async {
    _voiceNav?.recordAgentDiagnostic('opened');
    _wakeDialogue = true;
    _wakeGeneration++;
    await _wakeChannel.invokeMethod<void>('stopWake');
    if (!mounted) return;
    final nav = _voiceNav;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => VoiceTestPage(
              routeSnapshot: _voiceRouteSnapshot,
              savedSlots: _voiceSavedSlots,
              confirmSavedDestinationByVoice: _confirmSavedVoiceDestination,
              confirmDestinationByVoice: _confirmVoiceDestination,
              findNearbyByVoice: _findNearbyByVoice,
              answerQuery: (transcript, english) => answerVoiceQuery(transcript,
                  english: english,
                  state: nav?.current,
                  reliable: nav?.voiceGuidanceReliable ?? false,
                  navigationActive: nav?.phase == NavPhase.navigating,
                  remainingSeconds: nav?.voiceRemainingSeconds),
              shouldDeferNonUrgentReply: () => _navigationSpeechSpeaking,
            )));
    _wakeDialogue = false;
    _voiceNav?.recordAgentDiagnostic('closed');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (mounted) await _armWake();
  }

  void _handleAgentAction(_AgentAction action) {
    switch (action) {
      case _AgentAction.open:
        _openAgent();
        return;
      case _AgentAction.guidance:
        setState(() => _voiceEnabled = !_voiceEnabled);
        _voice.reset();
        if (_voiceEnabled) {
          _announce();
        } else {
          _silence();
        }
        return;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nav = context.read<NavigationController>();
    if (identical(nav, _voiceNav)) return;
    _voiceNav?.removeListener(_announce);
    _voiceNav?.removeListener(_syncWakeTrip);
    _voiceNav = nav;
    nav.addListener(_announce);
    nav.addListener(_syncWakeTrip);
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
    if (state == null ||
        state.direction == DeviceDirection.stop ||
        state.rerouting ||
        (nav.phase != NavPhase.navigating && nav.phase != NavPhase.arrived)) {
      if (!_wakeDialogue) _silence();
      return;
    }
    final message = _voice.next(state, nav.selectedRoute, nav.voiceStepIndex,
        english: AppText.of(context).isEnglish);
    if (message != null) _speak(message);
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
    WidgetsBinding.instance.removeObserver(this);
    _wakeGeneration++;
    _voiceNav?.removeListener(_syncWakeTrip);
    _wakeChannel.setMethodCallHandler(null);
    _wakeChannel.invokeMethod<void>('stopWake').catchError((_) {});
    _voiceNav?.removeListener(_announce);
    _silence();
    super.dispose();
  }

  Future<void> _start() async {
    final destination = _destination;
    if (destination == null) return;
    // Ask before the ride, never interrupt a moving rider with consent UI.
    if (await VoiceTripAccess.shouldAskAtTripStart()) {
      if (!mounted) return;
      final choice = await showVoiceTripAccessPrompt(context);
      if (!mounted) return;
      if (choice != null) await VoiceTripAccess.save(choice);
    }
    if (!mounted) return;
    bool wakeConsent = false;
    try {
      wakeConsent = await _wakeConsentForTrip();
    } catch (_) {
      // Optional voice setup must never prevent the rider from navigating.
    }
    if (!mounted) return;
    bool wakeReady = false;
    if (wakeConsent) {
      try {
        final credentials = await _wakeChannel
            .invokeMapMethod<String, String>('loadVoiceCredentials');
        wakeReady = credentials?['token']?.isNotEmpty == true;
      } catch (_) {
        wakeReady = false;
      }
    }
    if (!mounted) return;
    final nav = context.read<NavigationController>();
    await nav.startNavigation(destination.location);
    if (mounted &&
        nav.phase == NavPhase.navigating &&
        nav.selectedRoute != null) {
      setState(() => _routeAnimationId++);
      if (wakeReady) {
        await _enableWakeForTrip();
      } else if (wakeConsent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppText.of(context).isEnglish
                ? 'Voice wake needs gateway settings in Agent. Navigation is still running.'
                : '语音唤醒需要先在 Agent 中设置服务口令；导航仍正常运行。')));
      }
    }
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

  Future<String> _findNearbyByVoice(
      String category,
      String brand,
      bool en,
      bool Function() isCurrent,
      Future<String> Function(String, String) ask) async {
    final nav = context.read<NavigationController>();
    if (nav.phase != NavPhase.navigating || nav.destination == null) {
      return en
          ? 'Start navigation before asking me to replace its destination. Your route has not changed.'
          : '请先开始导航，之后才能用语音更换终点。路线没有更改。';
    }
    final origin = await nav.refreshVoiceSearchOrigin();
    final previous = nav.destination;
    bool valid() =>
        mounted &&
        isCurrent() &&
        identical(previous, nav.destination) &&
        nav.voiceSearchOrigin != null &&
        origin != null &&
        origin.distanceTo(nav.voiceSearchOrigin!) <= 250;
    if (origin == null || previous == null) {
      return en
          ? 'I could not get a recent accurate location. Please check location access and try again. Your route has not changed.'
          : '暂时无法取得近期准确定位。请检查定位权限后重试，路线没有更改。';
    }
    const terms = {
      'fuel': 'petrol station',
      'parking': 'parking',
      'cafe': 'cafe',
      'restaurant': 'restaurant',
      'pharmacy': 'pharmacy'
    };
    if (!terms.containsKey(category)) {
      return en ? 'That place category is not supported yet.' : '暂不支持这类地点。';
    }
    final places = await AppleMapsService()
        .search('$brand ${terms[category]}', near: origin, category: category)
        .timeout(const Duration(seconds: 15));
    if (!valid()) {
      return en
          ? 'Location or navigation changed. Please try again.'
          : '定位或导航状态已变化，请重试。';
    }
    final candidates = nearbyCandidates(places, origin, brand);
    if (candidates.isEmpty) {
      return en
          ? 'No matching nearby places found. I will not substitute another brand. Your route has not changed.'
          : '没有找到符合条件的附近地点，不会替换成其他品牌，路线没有更改。';
    }
    final ranked = await nav.rankNearbyPlaces(candidates, origin, valid);
    if (!valid() || ranked.isEmpty) {
      return en
          ? 'Could not verify a reachable match from your current location. Your route has not changed.'
          : '暂时无法验证从当前位置可到达的匹配地点，路线没有更改。';
    }
    final best = ranked.first;
    final minutes = (best.seconds / 60).ceil();
    return _confirmVoiceDestination('', en, valid, ask,
        suppliedPlaces: [best.place],
        introduction: en
            ? 'Among nearby matches with available routes, this has the shortest estimated drive, about $minutes minutes. Opening hours are not verified. This replaces your destination, not an intermediate stop. '
            : '在已找到且可计算路线的附近匹配地点中，这个地点预计行驶时间最短，约 $minutes 分钟。尚未核实营业时间。这会更换终点，不是添加途经点。');
  }

  Future<String> _confirmVoiceDestination(String query, bool en,
      bool Function() isCurrent, Future<String> Function(String, String) ask,
      {List<PlaceResult>? suppliedPlaces, String introduction = ''}) async {
    final nav = context.read<NavigationController>();
    final previous = nav.destination;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    bool valid() =>
        mounted &&
        isCurrent() &&
        DateTime.now().isBefore(deadline) &&
        nav.phase == NavPhase.navigating &&
        identical(nav.destination, previous);
    final cancelled = en
        ? 'Destination change cancelled. Your route has not changed.'
        : '已取消更换目的地，路线没有更改。';
    if (previous == null || !valid()) {
      return en ? 'Start navigation first.' : '请先开始导航。';
    }
    final places = (suppliedPlaces ??
            await AppleMapsService()
                .search(query)
                .timeout(const Duration(seconds: 20)))
        .where((p) => p.name.trim().isNotEmpty)
        .take(3)
        .toList();
    if (!valid()) return cancelled;
    if (places.isEmpty) {
      return en
          ? 'No matching place found. Your route has not changed.'
          : '未找到匹配地点，路线没有更改。';
    }
    var index = 0;
    if (places.length > 1) {
      final spokenOptions = spokenPlaceOptions(places);
      final options = [
        for (var i = 0; i < places.length; i++) '${i + 1}. ${spokenOptions[i]}'
      ].join('. ');
      final answer = await ask(
          en
              ? 'I found these places. $options. Say first, second, third, or cancel.'
              : '找到以下地点：$options。请说第一个、第二个、第三个，或取消。',
          'choose_place');
      index = const {
            'select_one': 0,
            'select_two': 1,
            'select_three': 2
          }[answer] ??
          -1;
      if (!valid() || index < 0 || index >= places.length) return cancelled;
    }
    final place = places[index];
    final spokenPlace = spokenPlaceOptions(places)[index];
    final answer = await ask(
        en
            ? '${introduction}Change destination to $spokenPlace? Say confirm or cancel.'
            : '$introduction确认将目的地更换为$spokenPlace吗？请说确认或取消。',
        'confirm_destination');
    if (!valid() || answer != 'confirm') return cancelled;
    final changed = await nav.changeDestination(place.location,
        expectedDestination: previous, stillConfirmed: valid);
    if (!mounted || !isCurrent()) return cancelled;
    if (!changed) {
      return en
          ? 'New route unavailable. Your existing route has not been replaced.'
          : '新路线暂不可用，没有替换原有路线。';
    }
    setState(() => _destination = place);
    return en
        ? 'Destination changed to $spokenPlace. The new route is ready.'
        : '目的地已更换为$spokenPlace，新路线已就绪。';
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
      floatingActionButton: Material(
        color: const Color(0xFF1668C9),
        elevation: 4,
        shape: const CircleBorder(),
        child: PopupMenuButton<_AgentAction>(
          tooltip: _wakeEnabled && _wakeState.startsWith('listening')
              ? (AppText.of(context).isEnglish
                  ? 'Voice agent listening for wake phrase'
                  : '语音 Agent 正在等待唤醒词')
              : (AppText.of(context).isEnglish ? 'Voice agent' : '语音 Agent'),
          icon: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
          onSelected: _handleAgentAction,
          itemBuilder: (context) {
            final en = AppText.of(context).isEnglish;
            return [
              PopupMenuItem(
                  value: _AgentAction.open,
                  child: Text(en ? 'Talk to Agent' : '与 Agent 对话')),
              PopupMenuItem(
                  value: _AgentAction.guidance,
                  child: Text(_voiceEnabled
                      ? (en ? 'Turn off guidance voice' : '关闭导航播报')
                      : (en ? 'Turn on guidance voice' : '开启导航播报'))),
            ];
          },
        ),
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        final landscape = constraints.maxWidth > constraints.maxHeight;
        final safe = MediaQuery.paddingOf(context);
        final panelWidth = landscape ? 320.0 : constraints.maxWidth - 32;
        // Reserve space for native map attribution and route framing.
        final mapInsets = EdgeInsets.fromLTRB(
          landscape ? panelWidth + 32 : 16,
          safe.top + (landscape ? 8 : 96),
          16,
          safe.bottom + (landscape ? 40 : 230),
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
                routeAnimationId: _routeAnimationId,
                mapStyle: _mapStyle,
                showTraffic: _showTraffic,
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
              top: safe.top + 108,
              right: 16,
              child: Material(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: 0.88),
                shape: const CircleBorder(),
                elevation: 2,
                child: IconButton(
                  onPressed: _openMapSettings,
                  tooltip:
                      AppText.of(context).isEnglish ? 'Map settings' : '地图设置',
                  icon: const Icon(Icons.settings_outlined, size: 19),
                  constraints:
                      const BoxConstraints(minWidth: 44, minHeight: 44),
                ),
              ),
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
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
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
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: TextButton.icon(
              onPressed: canStart && destination != null ? onStart : null,
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
