import 'package:flutter/cupertino.dart';
import '../controllers/navigation_controller.dart';
import '../l10n/app_text.dart';
import 'navio_theme.dart';

class RoutePreferencesPage extends StatefulWidget {
  const RoutePreferencesPage({super.key, required this.nav});
  final NavigationController nav;
  @override
  State<RoutePreferencesPage> createState() => _RoutePreferencesPageState();
}

class _RoutePreferencesPageState extends State<RoutePreferencesPage> {
  bool saving = false;
  String? error;
  Future<void> save({
    bool? highways,
    bool? tolls,
    bool? ferries,
    bool? tunnels,
  }) async {
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
        tunnels: tunnels ?? widget.nav.avoidTunnels,
      );
    } catch (_) {
      if (mounted) {
        error = AppText.of(context).couldNotSavePlease;
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return NavioPage(
      navigationBar: CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        automaticallyImplyLeading: false,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.pop(context),
          child: Icon(CupertinoIcons.back, semanticLabel: text.backAction),
        ),
        middle: Text(text.routePreferences),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          child: Icon(CupertinoIcons.info, semanticLabel: text.aboutAvoidance),
          onPressed: () => showCupertinoDialog<void>(
            context: context,
            builder: (ctx) => CupertinoAlertDialog(
              title: Text(text.routePreferences),
              content: Text(text.savedAutomaticallyOnPhone),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(text.okAction),
                ),
              ],
            ),
          ),
        ),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            CupertinoListSection.insetGrouped(
              header: SectionLabel(text.routeOptionsHeader),
              footer: Text(text.savedAutomaticallyAppliesNext),
              children: [
                option(
                  text.preferAvoidingHighways,
                  widget.nav.avoidHighways,
                  (v) => save(highways: v),
                ),
                option(
                  text.preferAvoidingTolls,
                  widget.nav.avoidTolls,
                  (v) => save(tolls: v),
                ),
                option(
                  text.preferAvoidingFerries,
                  widget.nav.avoidFerries,
                  (v) => save(ferries: v),
                ),
                option(
                  text.avoidTunnels,
                  widget.nav.avoidTunnels,
                  (v) => save(tunnels: v),
                ),
              ],
            ),
            if (saving) const CupertinoActivityIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  error!,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            if (!widget.nav.canEditPreferences)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(text.changePreferencesBeforeStarting),
              ),
          ],
        ),
      ),
    );
  }

  Widget option(String label, bool value, ValueChanged<bool> change) =>
      CupertinoListTile(
        title: Text(label, maxLines: 2),
        trailing: CupertinoSwitch(
          value: value,
          onChanged: saving || !widget.nav.canEditPreferences ? null : change,
        ),
      );
}
