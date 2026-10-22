import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_text.dart';
import '../services/cloud_voice_client.dart';
import '../services/saved_places.dart';
import '../services/spoken_place_label.dart';
import '../services/voice_trip_access.dart';
import '../services/voice_language.dart';
import '../services/voice_navigation_query.dart';
import 'voice_trip_access_prompt.dart';

/// Explicit, foreground Gemini voice session.
class VoiceTestPage extends StatefulWidget {
  const VoiceTestPage(
      {super.key,
      this.wakeSession = false,
      this.answerQuery,
      this.routeSnapshot,
      this.shouldDeferNonUrgentReply,
      this.savedSlots,
      this.confirmSavedDestinationByVoice,
      this.confirmDestinationByVoice,
      this.findNearbyByVoice});
  final bool wakeSession;
  final String Function(bool english)? routeSnapshot;

  /// True only while a navigation instruction is actually being spoken.
  final bool Function()? shouldDeferNonUrgentReply;
  final Future<List<String>> Function()? savedSlots;
  final Future<String> Function(
          String slot,
          bool english,
          bool Function() isCurrent,
          Future<String> Function(String prompt, String state) ask)?
      confirmSavedDestinationByVoice;
  final Future<String> Function(
      String category,
      String brand,
      bool english,
      bool Function() isCurrent,
      Future<String> Function(String, String) ask)? findNearbyByVoice;
  final Future<String> Function(
          String query,
          bool english,
          bool Function() isCurrent,
          Future<String> Function(String prompt, String state) ask)?
      confirmDestinationByVoice;
  final String Function(String transcript, bool english)? answerQuery;
  @override
  State<VoiceTestPage> createState() => _VoiceTestPageState();
}

class _VoiceTestPageState extends State<VoiceTestPage>
    with WidgetsBindingObserver {
  static const _voice = MethodChannel('moto_nav_bridge/voice');
  final _endpoint =
      TextEditingController(text: 'https://nav.williamligallery.uk/v1/voice');
  final _token = TextEditingController();
  final _cloud = CloudVoiceClient();
  bool _loadingCredentials = true;
  bool _credentialsSaved = false;
  bool _savingCredentials = false;
  String? _credentialError;
  String? _message;
  bool _busy = false;
  bool _listening = false;
  bool _routeAccess = false;
  bool _routeAccessDecided = false;
  int _generation = 0;
  final List<Map<String, String>> _dialogueHistory = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCredentials();
  }

  Future<void> _loadCredentials() async {
    try {
      _routeAccessDecided = await VoiceTripAccess.hasDecision();
      _routeAccess = await VoiceTripAccess.isEnabled();
    } catch (_) {
      // A failed optional permission read must not hide saved credentials.
      _routeAccess = false;
    }
    try {
      final saved =
          await _voice.invokeMapMethod<String, String>('loadVoiceCredentials');
      if (!mounted) return;
      if (saved?['endpoint'] != null) _endpoint.text = saved!['endpoint']!;
      _token.text = saved?['token'] ?? '';
      _credentialsSaved = _token.text.isNotEmpty && saved?['endpoint'] != null;
    } catch (_) {
      if (mounted) {
        setState(
            () => _message = 'Unable to load saved credentials / 无法读取已保存的凭证');
      }
    } finally {
      if (mounted) {
        setState(() => _loadingCredentials = false);
        if (widget.wakeSession && _credentialsSaved) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _listenCloud();
          });
        }
      }
    }
  }

  Future<void> _setRouteAccess(bool value) async {
    if (!await VoiceTripAccess.setFromSettings(value)) return;
    if (mounted) {
      setState(() {
        _routeAccess = value;
        _routeAccessDecided = true;
      });
    }
  }

  Future<bool> _confirmTripAccess() async {
    if (_routeAccessDecided) return true;
    final choice = await showVoiceTripAccessPrompt(context);
    if (!mounted || choice == null) return false;
    if (!await VoiceTripAccess.save(choice)) return false;
    if (mounted) {
      setState(() {
        _routeAccess = choice == VoiceTripAccessChoice.allow;
        _routeAccessDecided = true;
      });
    }
    return mounted && _routeAccessDecided;
  }

  Future<String> _askVoice(String prompt, String state, bool en, int id) async {
    bool valid() => mounted && id == _generation;
    if (!valid() ||
        !await _waitForTurnWindow(
            id, en, DateTime.now().add(const Duration(seconds: 45)))) {
      return 'cancel';
    }
    setState(() => _message = prompt);
    final spoken = await _voice.invokeMethod<bool>(
        'speakAndWait', {'text': prompt, 'language': en ? 'en-AU' : 'zh-CN'});
    if (!valid() || spoken != true) return 'cancel';
    if (!await _waitForTurnWindow(
        id, en, DateTime.now().add(const Duration(seconds: 45)))) {
      return 'cancel';
    }
    final audio = await _voice.invokeMethod<Uint8List>('recordCloudAudio');
    if (!valid() || audio == null || audio.isEmpty) return 'cancel';
    final result = await _cloud.converse(
        _endpoint.text.trim(), _token.text.trim(), audio,
        context: state);
    return valid() ? result['decision']! : 'cancel';
  }

  Future<void> _settings() async {
    final en = AppText.of(context).isEnglish;
    final endpoint = TextEditingController(text: _endpoint.text);
    final token = TextEditingController(text: _token.text);
    final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(en ? 'Voice gateway settings' : '语音服务设置'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: endpoint,
                      autocorrect: false,
                      decoration: const InputDecoration(
                          labelText: 'HTTPS gateway URL')),
                  TextField(
                      controller: token,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                          labelText: en
                              ? 'Gateway token (not API key)'
                              : '服务口令（不是 API Key）')),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(en ? 'Cancel' : '取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(en ? 'Save securely' : '安全保存')),
                ]));
    final values = {
      'endpoint': endpoint.text.trim(),
      'token': token.text.trim()
    };
    // Dialog controllers remain alive through the closing animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    endpoint.dispose();
    token.dispose();
    if (!mounted || save != true) return;
    await _saveCredentials(values);
  }

  Future<void> _saveCredentials(Map<String, String> values) async {
    if (_savingCredentials) return;
    final en = AppText.of(context).isEnglish;
    setState(() {
      _savingCredentials = true;
      _credentialError = null;
    });
    try {
      await _voice.invokeMethod<void>('saveVoiceCredentials', values);
      if (!mounted) return;
      setState(() {
        _endpoint.text = values['endpoint']!;
        _token.text = values['token']!;
        _credentialsSaved = true;
        _message = en ? 'Saved securely on this iPhone.' : '已安全保存在这台 iPhone。';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _credentialError =
            en ? 'Could not save. Check URL and token.' : '保存失败，请检查地址和口令。');
      }
    } finally {
      if (mounted) setState(() => _savingCredentials = false);
    }
  }

  Future<void> _listenCloud() async {
    final en = AppText.of(context).isEnglish;
    if (_token.text.isEmpty) {
      await _settings();
      return;
    }
    if (!await _confirmTripAccess() || !mounted) return;
    final consent = widget.wakeSession
        ? true
        : await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: Text(en
                        ? 'Send this recording to Gemini?'
                        : '将这次录音发送给 Gemini？'),
                    content: Text(en
                        ? 'This conversation uploads each recording and up to three recent turns to Google. If AI trip access is enabled, a limited route snapshot and saved place labels are also sent. Gemini may propose a destination, but the App requires spoken confirmation. Free-tier data may be used to improve services. Avoid private information. Set up while parked.'
                        : '对话录音和最近最多三轮内容会上传 Google。开启 AI 行程权限后，还会发送有限的路线摘要及已保存地点标签。Gemini 可提出新目的地，但 App 必须获得语音确认。免费服务的数据可能用于改进服务，请勿说出私人信息。请停车设置。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(en ? 'Cancel' : '取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(en ? 'Record' : '开始录音'))
                    ]));
    if (!mounted || consent != true) return;
    final id = ++_generation;
    setState(() {
      _listening = false;
      _busy = true;
      _message = null;
    });
    try {
      if (!await _waitForTurnWindow(
          id, en, DateTime.now().add(const Duration(seconds: 45)))) {
        return;
      }
      if (widget.wakeSession) {
        await _voice.invokeMethod<bool>('speakAndWait', {
          'text': en ? 'Listening.' : '请说。',
          'language': en ? 'en-AU' : 'zh-CN'
        });
        if (!mounted || id != _generation) return;
      }
      if (!await _waitForTurnWindow(
          id, en, DateTime.now().add(const Duration(seconds: 45)))) {
        return;
      }
      setState(() {
        _listening = true;
        _busy = false;
      });
      final audio = await _voice.invokeMethod<Uint8List>('recordCloudAudio');
      if (!mounted || id != _generation) return;
      if (audio == null || audio.isEmpty) {
        setState(() => _message = en ? 'No speech detected.' : '没有检测到说话。');
        return;
      }
      setState(() {
        _listening = false;
        _busy = true;
      });
      final slots = _routeAccess && widget.savedSlots != null
          ? await widget.savedSlots!()
          : <String>[];
      final result = await _cloud.converse(
          _endpoint.text.trim(), _token.text.trim(), audio,
          history: _dialogueHistory,
          routeSnapshot:
              _routeAccess ? (widget.routeSnapshot?.call(en) ?? '') : '',
          tripAccess: _routeAccess,
          savedSlots: slots);
      if (!mounted || id != _generation) return;
      var reply = result['reply']!;
      final utterance = result['utterance'] ?? '';
      final turnEnglish = voiceTurnIsEnglish(utterance, fallbackEnglish: en);
      if (isVoiceRepeatRequest(utterance) && widget.answerQuery != null) {
        // Route facts come from the live controller, never from the model's
        // remembered text or an older route snapshot.
        reply = widget.answerQuery!(utterance, turnEnglish);
      } else if (_routeAccess &&
          result['action'] == 'destination_query' &&
          widget.confirmDestinationByVoice != null) {
        reply = await widget.confirmDestinationByVoice!(
            result['argument']!,
            turnEnglish,
            () => mounted && id == _generation,
            (prompt, state) => _askVoice(prompt, state, turnEnglish, id));
      } else if (_routeAccess &&
          result['action'] == 'saved_place' &&
          widget.confirmSavedDestinationByVoice != null &&
          slots.contains(result['argument'])) {
        reply = await widget.confirmSavedDestinationByVoice!(
            result['argument']!,
            turnEnglish,
            () => mounted && id == _generation,
            (prompt, state) => _askVoice(prompt, state, turnEnglish, id));
      } else if (_routeAccess &&
          result['action'] == 'read_saved_place' &&
          slots.contains(result['argument'])) {
        final place = (await SavedPlaces().load())[result['argument']];
        final label = switch (result['argument']) {
          'home' => turnEnglish ? 'home' : '家',
          'work' => turnEnglish ? 'work' : '公司',
          _ => turnEnglish ? 'school' : '学校',
        };
        reply = place == null
            ? (turnEnglish
                ? 'That saved address is unavailable.'
                : '没有找到这个已保存地址。')
            : (turnEnglish
                ? 'Your saved $label is ${spokenPlaceLabel(place)}.'
                : '已保存的$label是${spokenPlaceLabel(place)}。');
      }
      if (!mounted || id != _generation) return;
      if (utterance.isNotEmpty && result['action'] != 'read_saved_place') {
        _dialogueHistory.add({
          'user': utterance,
          'assistant': reply.length <= 240 ? reply : reply.substring(0, 240),
        });
        if (_dialogueHistory.length > 3) _dialogueHistory.removeAt(0);
      }
      setState(() => _message = reply);
      await _speakReply(
          reply, voiceReplyIsEnglish(reply, fallbackEnglish: turnEnglish), id);
    } catch (_) {
      if (mounted && id == _generation) {
        setState(() => _message = en
            ? 'Voice request failed. Check gateway audio deployment, token and quota. Your route has not changed.'
            : '语音请求失败，请检查服务端音频接口部署、口令及额度。路线没有更改。');
      }
    } finally {
      if (mounted && id == _generation) {
        setState(() {
          _listening = false;
          _busy = false;
        });
        if (widget.wakeSession) Navigator.of(context).pop();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cancel();
    }
  }

  Future<void> _cancel() async {
    _generation++;
    _cloud.cancel();
    try {
      await _voice.invokeMethod<void>('stop');
      await _voice.invokeMethod<void>('cancelListen');
    } catch (_) {}
    if (mounted) {
      setState(() {
        _busy = false;
        _listening = false;
      });
    }
  }

  Future<void> _speakReply(String response, bool en, int id) async {
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!await _waitForTurnWindow(id, en, deadline)) return;
        if (!mounted || id != _generation) return;
        setState(() => _message = response);
        final spoken = await _voice.invokeMethod<bool>('speakAndWait',
            {'text': response, 'language': en ? 'en-AU' : 'zh-CN'});
        if (!mounted || id != _generation) return;
        if (spoken == true) return;
        // Navigation speech may have interrupted the answer. Retry after the
        // announcement; never re-run the Gemini action itself.
        if (widget.shouldDeferNonUrgentReply?.call() != true ||
            DateTime.now().isAfter(deadline)) {
          break;
        }
      }
      if (mounted && id == _generation) {
        setState(() => _message =
            '$response\n${en ? 'Speech was cancelled or unavailable.' : '语音播放被取消或不可用。'}');
      }
    } catch (_) {
      if (mounted && id == _generation) {
        setState(() => _message =
            '$response\n${en ? 'Audio reply unavailable.' : '语音播报暂不可用。'}');
      }
    }
  }

  Future<bool> _waitForTurnWindow(int id, bool en, DateTime deadline) async {
    if (!mounted || id != _generation) return false;
    if (widget.shouldDeferNonUrgentReply?.call() != true) return true;
    setState(() => _message = en
        ? 'Navigation is speaking. I will continue when it finishes.'
        : '导航正在播报，播报结束后我会继续。');
    while (widget.shouldDeferNonUrgentReply?.call() == true) {
      if (!mounted || id != _generation) return false;
      if (DateTime.now().isAfter(deadline)) {
        setState(() => _message = en
            ? 'Navigation speech has not finished. Please try again shortly.'
            : '导航播报尚未结束，请稍后再试。');
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return mounted && id == _generation;
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _voice.invokeMethod<void>('cancelListen').catchError((_) {});
    _voice.invokeMethod<void>('stop').catchError((_) {});
    _cloud.close();
    _endpoint.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final en = AppText.of(context).isEnglish;
    final disabled =
        _busy || _listening || _loadingCredentials || _savingCredentials;
    return Scaffold(
        appBar: AppBar(title: Text(en ? 'Voice assistant' : '语音助手'), actions: [
          IconButton(
              onPressed: disabled ? null : _settings,
              icon: const Icon(Icons.settings_outlined),
              tooltip: en ? 'Voice settings' : '语音设置')
        ]),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          if (!_loadingCredentials && !_credentialsSaved) ...[
            Text(en ? 'Set up voice service' : '设置语音服务',
                style: Theme.of(context).textTheme.titleLarge),
            Text(en
                ? 'Enter your gateway token once. These fields hide only after a successful save.'
                : '首次填写服务口令，保存成功后才会隐藏这两项。'),
            TextField(
                key: const ValueKey('gateway-url'),
                controller: _endpoint,
                enabled: !_savingCredentials,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration:
                    const InputDecoration(labelText: 'HTTPS gateway URL')),
            TextField(
                key: const ValueKey('gateway-token'),
                controller: _token,
                enabled: !_savingCredentials,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                    labelText: en
                        ? 'Gateway token (not Gemini API key)'
                        : '服务口令（不是 Gemini API Key）')),
            FilledButton(
                key: const ValueKey('save-gateway'),
                onPressed: _savingCredentials
                    ? null
                    : () => _saveCredentials({
                          'endpoint': _endpoint.text.trim(),
                          'token': _token.text.trim()
                        }),
                child: Text(en ? 'Save and hide' : '保存并隐藏')),
          ],
          if (_credentialError != null) Text(_credentialError!),
          FilledButton.icon(
              onPressed: disabled ? null : _listenCloud,
              icon: const Icon(Icons.graphic_eq),
              label: Text(en ? 'Talk to Agent' : '与 Agent 对话')),
          Text(en
              ? 'Audio is uploaded only after your consent. Set up while parked.'
              : '仅在同意后上传音频，请停车测试。'),
          Text(en
              ? 'Talk naturally with Gemini. Trip access lets it read a limited route snapshot and propose destination changes. Every change needs spoken confirmation.'
              : '可与 Gemini 自由对话。行程权限让它读取有限的路线摘要并提出更换目的地；每次更改都必须语音确认。'),
          SwitchListTile(
            title: Text(en ? 'AI trip access' : 'AI 行程权限'),
            subtitle: Text(en
                ? 'Share current route summary and saved place labels only when speaking. Turning this off also stops automatic prompts; you can enable it here anytime.'
                : '仅在对话时分享当前路线摘要和已保存地点标签。此处关闭后也会停止自动询问，随时可重新开启。'),
            value: _routeAccess,
            onChanged: disabled ? null : _setRouteAccess,
          ),
          if (!_routeAccess && _routeAccessDecided)
            Text(en
                ? 'Trip access is off. Agent cannot answer questions about your current route.'
                : '行程访问已关闭，Agent 无法回答当前路线的问题。'),
          if (_busy || _listening) ...[
            const LinearProgressIndicator(),
            Text(_listening
                ? (en ? 'Listening…' : '正在聆听…')
                : (en ? 'Processing voice request…' : '正在处理语音请求…')),
            TextButton(onPressed: _cancel, child: Text(en ? 'Cancel' : '取消')),
          ],
          if (_message != null)
            Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_message!)),
        ]));
  }
}
