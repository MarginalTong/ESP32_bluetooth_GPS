import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_text.dart';
import '../models/place_result.dart';
import 'widgets/saved_places_bar.dart';

class MapSettingsPage extends StatefulWidget {
  const MapSettingsPage({super.key});

  static const styleKey = 'map_style_v1';
  static const trafficKey = 'map_traffic_v1';

  @override
  State<MapSettingsPage> createState() => _MapSettingsPageState();
}

class _MapSettingsPageState extends State<MapSettingsPage> {
  String style = 'standard';
  bool traffic = false;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      final saved = prefs.getString(MapSettingsPage.styleKey);
      style =
          {'standard', 'standard_dark', 'hybrid', 'satellite'}.contains(saved)
              ? saved!
              : 'standard';
      traffic = prefs.getBool(MapSettingsPage.trafficKey) ?? false;
      loaded = true;
    });
  }

  Future<void> _setStyle(String value) async {
    final previous = style;
    setState(() => style = value);
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(MapSettingsPage.styleKey, value) && mounted) {
      setState(() => style = previous);
    }
  }

  Future<void> _setTraffic(bool value) async {
    final previous = traffic;
    setState(() => traffic = value);
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(MapSettingsPage.trafficKey, value) && mounted) {
      setState(() => traffic = previous);
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = AppText.of(context).isEnglish;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        middle: Text(en ? 'Map settings' : '地图设置'),
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
                header: Text(en ? 'MAP APPEARANCE' : '地图外观'),
                children: [
                  _styleTile('standard', en ? 'Standard' : '标准',
                      en ? 'Clear streets and landmarks' : '清晰显示道路与地标'),
                  _styleTile(
                      'standard_dark',
                      en ? 'Standard · Dark' : '标准 · 深色',
                      en ? 'A calmer map for night riding' : '适合夜间骑行的深色地图'),
                  _styleTile('hybrid', en ? 'Hybrid' : '混合',
                      en ? 'Aerial imagery with road labels' : '航拍影像与道路标注'),
                  _styleTile('satellite', en ? 'Satellite' : '卫星',
                      en ? 'Aerial imagery without labels' : '不显示道路标注的航拍影像'),
                ],
              ),
              CupertinoListSection.insetGrouped(
                header: Text(en ? 'MAP DETAILS' : '地图信息'),
                children: [
                  CupertinoListTile(
                    title: Text(en ? 'Show traffic' : '显示交通状况'),
                    subtitle: Text(en
                        ? 'Display only · Standard and Hybrid maps'
                        : '仅供查看 · 适用于标准和混合地图'),
                    trailing: CupertinoSwitch(
                      value: traffic,
                      onChanged: style == 'satellite' ? null : _setTraffic,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 0, 36, 4),
                child: Text(
                  en
                      ? 'Traffic does not change navigation routes.'
                      : '交通显示不会改变导航路线。',
                  style: const TextStyle(
                      fontSize: 12, color: CupertinoColors.secondaryLabel),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 18, 36, 0),
                child: Text(en ? 'SAVED PLACES' : '常用地址',
                    style: const TextStyle(
                        fontSize: 13, color: CupertinoColors.secondaryLabel)),
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
          ? const Icon(CupertinoIcons.check_mark,
              color: CupertinoColors.activeBlue, size: 20)
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
          const Offset(12, 14), 18, Paint()..color = const Color(0xff749270));
      canvas.drawCircle(
          const Offset(41, 36), 19, Paint()..color = const Color(0xff385c62));
    } else {
      canvas.drawCircle(
          const Offset(37, 7),
          17,
          Paint()
            ..color = dark ? const Color(0xff243d43) : const Color(0xffb9d9c3));
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
