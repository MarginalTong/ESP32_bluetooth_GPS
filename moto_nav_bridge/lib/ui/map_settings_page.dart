import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_text.dart';
import '../models/place_result.dart';
import 'widgets/saved_places_bar.dart';
import 'navio_theme.dart';
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
    final previous = style;
    setState(() => style = value);
    final prefs = await SharedPreferences.getInstance();
    try {
      await SettingsStore.edit(prefs, () async {
        if (!await prefs.setString(MapSettingsPage.styleKey, value)) {
          throw StateError('Save failed');
        }
      }, expectedActor: _loadedActor);
    } catch (_) {
      if (mounted) {
        setState(() => style = previous);
      }
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
              CupertinoListSection.insetGrouped(
                header: SectionLabel(text.mapAppearanceHeader),
                children: [
                  _styleTile(
                    'standard',
                    text.mapStyleStandard,
                    text.clearStreetsLandmarks,
                  ),
                  _styleTile(
                    'standard_dark',
                    text.mapStyleStandardDark,
                    text.calmerMapNightRiding,
                  ),
                  _styleTile(
                    'hybrid',
                    text.mapStyleHybrid,
                    text.aerialImageryRoadLabels,
                  ),
                  _styleTile(
                    'satellite',
                    text.mapStyleSatellite,
                    text.aerialImageryWithoutLabels,
                  ),
                ],
              ),
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
    return CupertinoListTile(
      onTap: () => _setStyle(value),
      leading: _MapStylePreview(style: value),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: selected
          ? const Icon(
              CupertinoIcons.check_mark,
              color: CupertinoColors.activeBlue,
              size: 20,
            )
          : null,
    );
  }
}

class _MapStylePreview extends StatelessWidget {
  const _MapStylePreview({required this.style});
  final String style;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(11),
    child: SizedBox.square(
      dimension: 46,
      child: CustomPaint(painter: _MapPreviewPainter(style)),
    ),
  );
}

class _MapPreviewPainter extends CustomPainter {
  const _MapPreviewPainter(this.style);
  final String style;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = style == 'standard_dark';
    final imagery = style == 'hybrid' || style == 'satellite';
    canvas.drawColor(
      dark
          ? const Color(0xff172536)
          : imagery
          ? const Color(0xff577963)
          : const Color(0xffe9ede7),
      BlendMode.src,
    );
    if (imagery) {
      canvas.drawCircle(
        const Offset(12, 14),
        18,
        Paint()..color = const Color(0xff749270),
      );
      canvas.drawCircle(
        const Offset(41, 36),
        19,
        Paint()..color = const Color(0xff385c62),
      );
    } else {
      canvas.drawCircle(
        const Offset(37, 7),
        17,
        Paint()
          ..color = dark ? const Color(0xff243d43) : const Color(0xffb9d9c3),
      );
    }
    if (style == 'satellite') return;
    final road = Paint()
      ..color = dark ? const Color(0xffa2aeb8) : Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(-4, 34), const Offset(50, 13), road);
    canvas.drawLine(const Offset(13, -4), const Offset(32, 50), road);
    final route = Paint()
      ..color = dark ? const Color(0xff63aaff) : const Color(0xffe99836)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(4, 31), const Offset(42, 16), route);
  }

  @override
  bool shouldRepaint(covariant _MapPreviewPainter oldDelegate) =>
      oldDelegate.style != style;
}
