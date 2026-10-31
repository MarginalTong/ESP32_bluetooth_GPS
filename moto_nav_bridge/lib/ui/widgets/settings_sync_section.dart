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
    final en = AppText.of(context).isEnglish;
    final status = sync?.status;
    final label = switch (status) {
      SettingsSyncStatus.synced => en ? 'Up to date' : '已同步',
      SettingsSyncStatus.syncing => en ? 'Syncing…' : '正在同步…',
      SettingsSyncStatus.offline =>
        en ? 'Waiting to sync · tap to retry' : '等待同步 · 点击重试',
      SettingsSyncStatus.conflict => en ? 'Settings need review' : '设置冲突，请确认',
      SettingsSyncStatus.deferred =>
        en ? 'Saved locally · sync when idle' : '已保存在本机，空闲时同步',
      SettingsSyncStatus.pending =>
        en ? 'Changes saved on this phone' : '修改已保存在本机',
      _ => en ? 'Sync unavailable in this build' : '此版本暂不可同步设置',
    };
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.only(top: 16),
      footer: Text(
        en
            ? 'Saved places and map/route preferences sync automatically. Bluetooth keys and location history stay off the cloud. Guest settings remain separate.'
            : '常用地址、地图与路线偏好自动同步。不上传蓝牙密钥或定位轨迹，游客资料独立保留。',
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
      children: [
        CupertinoListTile(
          leading: Icon(
            status == SettingsSyncStatus.conflict
                ? CupertinoIcons.exclamationmark_circle
                : CupertinoIcons.cloud,
            size: 23,
            color: CupertinoColors.systemBlue,
          ),
          title: Text(
            en ? 'Automatic sync' : '自动同步',
            style: const TextStyle(fontSize: 16),
          ),
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
                      title: Text(
                        en ? 'Review conflicting settings' : '确认冲突设置',
                      ),
                      message: Text(
                        en
                            ? 'Some values changed both here and on another device. Choose which conflicting values to keep. Other changes will still be merged.'
                            : '部分设置在本机和其他设备都被修改。请选择冲突项保留哪份；其他修改仍会合并。',
                      ),
                      actions: [
                        CupertinoActionSheetAction(
                          onPressed: () =>
                              Navigator.pop(dialog, SettingsChoice.local),
                          child: Text(
                            en
                                ? 'Keep this phone’s conflicting values'
                                : '冲突项保留本机版本',
                          ),
                        ),
                        CupertinoActionSheetAction(
                          onPressed: () =>
                              Navigator.pop(dialog, SettingsChoice.cloud),
                          child: Text(
                            en ? 'Use cloud values for conflicts' : '冲突项使用云端版本',
                          ),
                        ),
                      ],
                      cancelButton: CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(dialog),
                        child: Text(en ? 'Cancel' : '取消'),
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
