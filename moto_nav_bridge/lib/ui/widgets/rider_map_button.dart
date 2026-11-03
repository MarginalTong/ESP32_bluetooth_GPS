import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/rider_map_controller.dart';
import '../../l10n/app_text.dart';
import '../navio_theme.dart';

class RiderMapButton extends StatelessWidget {
  const RiderMapButton({super.key, required this.dark});
  final bool dark;
  @override
  Widget build(BuildContext context) {
    final riders = context.watch<RiderMapController?>();
    if (riders == null) return const SizedBox.shrink();
    final text = AppText.of(context);
    return Material(
      color: dark ? NavioColors.mapControlDark : Colors.white,
      shape: const CircleBorder(),
      elevation: 1,
      child: IconButton(
        tooltip: text.sydneyRiders,
        icon: Icon(
          riders.viewing ? Icons.people : Icons.people_outline,
          color: dark ? Colors.white : null,
        ),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          builder: (_) => ChangeNotifierProvider.value(
            value: riders,
            child: const _RiderSettings(),
          ),
        ),
      ),
    );
  }
}

class _RiderSettings extends StatelessWidget {
  const _RiderSettings();
  @override
  Widget build(BuildContext context) {
    final riders = context.watch<RiderMapController>();
    final text = AppText.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text.sydneyRiders,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(text.onlyRidersWhoChoose),
              if (!riders.signedIn)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(text.signInUnderMy),
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(text.showRiders),
                subtitle: Text(text.ridersRefreshHint),
                value: riders.viewing,
                onChanged: riders.signedIn ? riders.setViewing : null,
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(text.shareMyPositionDuring),
                subtitle: Text(text.publicSignedInNavio),
                value: riders.sharing,
                onChanged: !riders.signedIn
                    ? null
                    : (value) async {
                        if (!value) {
                          riders.setSharing(false);
                          return;
                        }
                        final agreed = await showDialog<bool>(
                          context: context,
                          builder: (dialog) => AlertDialog(
                            title: Text(text.shareLocationPublicly),
                            content: Text(text.otherSignedInUsers),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialog, false),
                                child: Text(text.cancelAction),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(dialog, true),
                                child: Text(text.agreeShare),
                              ),
                            ],
                          ),
                        );
                        if (context.mounted && agreed == true) {
                          riders.setSharing(true);
                        }
                      },
              ),
              if (riders.sharing)
                Text(
                  riders.active
                      ? (text.sharingWhenAccurateFresh)
                      : (text.notSharingNowWaiting),
                ),
              if (riders.truncated) Text(text.showingUp500Riders),
              if (riders.error != null)
                Text(
                  text.riderServiceUnavailableNavigation,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
