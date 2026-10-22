import 'package:flutter/cupertino.dart';
import '../controllers/navigation_controller.dart';
import '../l10n/app_text.dart';

class RoutePreferencesPage extends StatefulWidget {
  const RoutePreferencesPage({super.key, required this.nav});
  final NavigationController nav;
  @override
  State<RoutePreferencesPage> createState() => _RoutePreferencesPageState();
}

class _RoutePreferencesPageState extends State<RoutePreferencesPage> {
  bool saving = false;
  String? error;
  Future<void> save(
      {bool? highways, bool? tolls, bool? ferries, bool? tunnels}) async {
    if (saving || !widget.nav.canEditPreferences) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.nav.savePreferences(
          highways: highways ?? widget.nav.avoidHighways,
          tolls: tolls ?? widget.nav.avoidTolls,
          ferries: ferries ?? widget.nav.avoidFerries,
          tunnels: tunnels ?? widget.nav.avoidTunnels);
    } catch (_) {
      if (mounted) {
        error = AppText.of(context).isEnglish
            ? 'Could not save. Please try again.'
            : '保存失败，请重试。';
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = AppText.of(context).isEnglish;
    return CupertinoPageScaffold(
        backgroundColor: CupertinoColors.systemGroupedBackground,
        navigationBar: CupertinoNavigationBar(
            transitionBetweenRoutes: false,
            automaticallyImplyLeading: false,
            leading: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.pop(context),
                child: Icon(CupertinoIcons.back,
                    semanticLabel: en ? 'Back' : '返回')),
            middle: Text(en ? 'Route preferences' : '路线偏好'),
            trailing: CupertinoButton(
                padding: EdgeInsets.zero,
                child: Icon(CupertinoIcons.info,
                    semanticLabel: en ? 'About avoidance' : '避让说明'),
                onPressed: () => showCupertinoDialog<void>(
                    context: context,
                    builder: (ctx) => CupertinoAlertDialog(
                            title: Text(en ? 'Route preferences' : '路线偏好'),
                            content: Text(en
                                ? 'Saved automatically on this phone. Highways, tolls and ferries are preferences, not guaranteed exclusions. Tunnels exclude mapped tunnel sections except at the start/end; map data may be incomplete. Change preferences before navigation. Saving clears the old route preview.'
                                : '自动保存在本机。高速、收费路和轮渡为尽量避开，并非保证排除。隧道会排除地图已标注路段（起终点所在路段除外），地图可能不完整。请在导航前修改，保存后清除旧路线预览。'),
                            actions: [
                              CupertinoDialogAction(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: Text(en ? 'OK' : '知道了'))
                            ])))),
        child: SafeArea(
            child: ListView(children: [
          CupertinoListSection.insetGrouped(children: [
            option(en ? 'Prefer avoiding highways' : '尽量避开高速',
                widget.nav.avoidHighways, (v) => save(highways: v)),
            option(en ? 'Prefer avoiding tolls' : '尽量避开收费路',
                widget.nav.avoidTolls, (v) => save(tolls: v)),
            option(en ? 'Prefer avoiding ferries' : '尽量避开轮渡',
                widget.nav.avoidFerries, (v) => save(ferries: v)),
            option(en ? 'Avoid tunnels' : '避开隧道', widget.nav.avoidTunnels,
                (v) => save(tunnels: v)),
          ]),
          if (saving) const CupertinoActivityIndicator(),
          if (error != null)
            Padding(
                padding: const EdgeInsets.all(20),
                child: Text(error!,
                    style: const TextStyle(color: CupertinoColors.systemRed))),
          if (!widget.nav.canEditPreferences)
            Padding(
                padding: const EdgeInsets.all(20),
                child: Text(en
                    ? 'Change preferences before starting navigation.'
                    : '请在开始导航前修改偏好。')),
        ])));
  }

  Widget option(String label, bool value, ValueChanged<bool> change) =>
      CupertinoListTile(
          title: Text(label, maxLines: 2),
          trailing: CupertinoSwitch(
              value: value,
              onChanged:
                  saving || !widget.nav.canEditPreferences ? null : change));
}
