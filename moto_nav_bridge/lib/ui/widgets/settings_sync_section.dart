import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../controllers/settings_sync_controller.dart';
import '../../models/settings_merge.dart';
import '../../l10n/app_text.dart';

class SettingsSyncSection extends StatelessWidget {
  const SettingsSyncSection({super.key});
  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SettingsSyncController?>();
    final text = AppText.of(context);
    final status = sync?.status;
    final label = switch (status) {
      SettingsSyncStatus.synced => text.upDate,
      SettingsSyncStatus.syncing => text.syncing,
      SettingsSyncStatus.offline => text.waitingSyncTapRetry,
      SettingsSyncStatus.conflict => text.settingsNeedReview,
      SettingsSyncStatus.deferred => text.savedLocallySyncWhen,
      SettingsSyncStatus.pending => text.changesSavedOnPhone,
      _ => text.syncUnavailableInBuild,
    };
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.only(top: 16),
      footer: Text(
        text.settingsSyncFooter,
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
      children: [
        CupertinoListTile(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          leading: Icon(
            status == SettingsSyncStatus.conflict
                ? CupertinoIcons.exclamationmark_circle
                : CupertinoIcons.cloud,
            size: 23,
            color: CupertinoColors.systemBlue,
          ),
          title: Text(text.automaticSync, style: const TextStyle(fontSize: 16)),
          subtitle: Text(
            label,
            style: const TextStyle(fontSize: 13),
            maxLines: 2,
          ),
          trailing: status == SettingsSyncStatus.syncing
              ? const CupertinoActivityIndicator(radius: 8)
              : null,
          onTap: status == SettingsSyncStatus.conflict
              ? () async {
                  final actor = sync!.account.user?.id;
                  final generation = sync.accountGeneration;
                  final choice = await showCupertinoModalPopup<SettingsChoice>(
                    context: context,
                    builder: (dialog) => CupertinoActionSheet(
                      title: Text(text.reviewConflictingSettings),
                      message: Text(text.someValuesChangedBoth),
                      actions: [
                        CupertinoActionSheetAction(
                          onPressed: () =>
                              Navigator.pop(dialog, SettingsChoice.local),
                          child: Text(text.keepPhoneSConflicting),
                        ),
                        CupertinoActionSheetAction(
                          onPressed: () =>
                              Navigator.pop(dialog, SettingsChoice.cloud),
                          child: Text(text.useCloudValuesConflicts),
                        ),
                      ],
                      cancelButton: CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(dialog),
                        child: Text(text.cancelAction),
                      ),
                    ),
                  );
                  if (choice != null &&
                      context.mounted &&
                      sync.account.user?.id == actor &&
                      sync.accountGeneration == generation) {
                    await sync.resolve(choice);
                  }
                }
              : status == SettingsSyncStatus.offline
              ? sync!.flush
              : null,
        ),
      ],
    );
  }
}
