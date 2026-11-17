import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_text.dart';
import '../models/place_result.dart';
import 'widgets/saved_places_bar.dart';
import 'widgets/map_style_preview.dart';
import 'navio_theme.dart';
import 'navio_feedback.dart';
import '../services/settings_store.dart';
import 'package:provider/provider.dart';
import '../controllers/account_controller.dart';

class MapSettingsPage extends StatefulWidget {
  const MapSettingsPage({super.key});

  static const styleKey = 'map_style_v1';

  @override
  State<MapSettingsPage> createState() => _MapSettingsPageState();
}

class _MapSettingsPageState extends State<MapSettingsPage> {
  String style = 'standard';
  bool loaded = false;
  bool _styleSaving = false;
  String? _loadedActor;
  String? _settingsStamp;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final account = context.watch<AccountController?>();
    final stamp = '${account?.localGeneration}:${account?.settingsRevision}';
    if (_settingsStamp != null && _settingsStamp != stamp) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    _settingsStamp = stamp;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _loadedActor = prefs.getString(SettingsStore.activeKey);
      final saved = prefs.getString(MapSettingsPage.styleKey);
      style =
          {'standard', 'standard_dark', 'hybrid', 'satellite'}.contains(saved)
          ? saved!
          : 'standard';
      loaded = true;
    });
  }

  Future<void> _setStyle(String value) async {
    if (_styleSaving || value == style) return;
    NavioFeedback.of(context).emit(InteractionFeedback.selection);
    final previous = style;
    setState(() {
      style = value;
      _styleSaving = true;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await SettingsStore.edit(prefs, () async {
        if (!await prefs.setString(MapSettingsPage.styleKey, value)) {
          throw StateError('Save failed');
        }
      }, expectedActor: _loadedActor);
    } catch (_) {
      if (mounted) {
        setState(() => style = previous);
      }
    } finally {
      if (mounted) setState(() => _styleSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return NavioPage(
      navigationBar: CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        middle: Text(text.mapSettings),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            if (!loaded)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CupertinoActivityIndicator()),
              )
            else ...[
              _appearance(text),
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 18, 36, 0),
                child: Text(
                  text.savedPlacesHeader,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
              ),
              SavedPlacesBar(
                onSelected: (PlaceResult place) =>
                    Navigator.pop(context, place),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _styleTile(String value, String title, String subtitle) {
    final selected = style == value;
    return Semantics(
      selected: selected,
      child: NavioPressEffect(
        enabled: !_styleSaving && !selected,
        child: CupertinoListTile(
          onTap: _styleSaving ? null : () => _setStyle(value),
          leading: MapStylePreview(style: value),
          title: Text(title),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: AnimatedSwitcher(
            duration: NavioMotion.duration(context, NavioMotion.stateChange),
            child: _styleSaving && selected
                ? const CupertinoActivityIndicator(key: ValueKey('saving'))
                : Icon(
                    selected
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle,
                    key: ValueKey(selected),
                    size: 22,
                    color: selected
                        ? CupertinoColors.activeBlue
                        : CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _appearance(AppText text) => CupertinoListSection.insetGrouped(
    header: SectionLabel(text.mapAppearanceHeader),
    children: [
      _styleTile('standard', text.mapStyleStandard, text.clearStreetsLandmarks),
      _styleTile(
        'standard_dark',
        text.mapStyleStandardDark,
        text.calmerMapNightRiding,
      ),
      _styleTile('hybrid', text.mapStyleHybrid, text.aerialImageryRoadLabels),
      _styleTile(
        'satellite',
        text.mapStyleSatellite,
        text.aerialImageryWithoutLabels,
      ),
    ],
  );
}
