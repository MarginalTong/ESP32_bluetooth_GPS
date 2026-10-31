import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../controllers/avatar_controller.dart';
import '../../l10n/app_text.dart';

/// The photo is its own control: tapping it offers every photo action in one
/// sheet, so the page itself never carries loose change/remove buttons.
class ProfileAvatarEditor extends StatelessWidget {
  const ProfileAvatarEditor({super.key});

  static const double _size = 96;

  Future<void> _openActions(
    BuildContext context,
    AvatarController controller,
    bool en,
  ) async {
    final hasPhoto = controller.avatar != null;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        message: Text(
          en
              ? 'Your photo is visible to signed-in riders only while you share your location. Only a small cropped copy is saved, not the original photo.'
              : '仅在共享位置时向已登录骑友展示头像。只保存裁剪后的小图，不上传原照片。',
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheet, 'choose'),
            child: Text(
              hasPhoto
                  ? (en ? 'Change photo' : '更换头像')
                  : (en ? 'Choose photo' : '设置头像'),
            ),
          ),
          if (hasPhoto)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(sheet, 'remove'),
              child: Text(en ? 'Remove photo' : '移除头像'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: Text(en ? 'Cancel' : '取消'),
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'choose') {
      await _choose(context, controller, en);
    } else if (action == 'remove') {
      await _remove(context, controller, en);
    }
  }

  Future<void> _choose(
    BuildContext context,
    AvatarController controller,
    bool en,
  ) => controller.choose(
    confirm: (jpeg) async =>
        await showCupertinoDialog<bool>(
          context: context,
          builder: (dialog) => CupertinoAlertDialog(
            title: Text(en ? 'Use this profile photo?' : '使用这个头像？'),
            content: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipOval(
                    child: Image.memory(
                      jpeg,
                      width: 128,
                      height: 128,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    en
                        ? 'Visible to riders when you share your location.'
                        : '共享位置时，骑友可以看到此头像。',
                  ),
                ],
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(en ? 'Cancel' : '取消'),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(en ? 'Use photo' : '使用头像'),
              ),
            ],
          ),
        ) ??
        false,
  );

  Future<void> _remove(
    BuildContext context,
    AvatarController controller,
    bool en,
  ) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(en ? 'Remove profile photo?' : '移除头像？'),
        content: Text(
          en
              ? 'Your account and rider marker will use the default avatar.'
              : '账号与骑友地图将恢复默认头像。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(en ? 'Cancel' : '取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(en ? 'Remove' : '移除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.remove();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AvatarController?>();
    if (controller == null) return const SizedBox.shrink();
    final en = AppText.of(context).isEnglish;
    final avatar = controller.avatar;
    final background = CupertinoColors.systemGroupedBackground.resolveFrom(
      context,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Column(
        children: [
          Semantics(
            button: true,
            label: en ? 'Edit profile photo' : '编辑个人头像',
            child: CupertinoButton(
              key: const ValueKey('profile-photo-button'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(_size, _size),
              onPressed: controller.canEdit && !controller.busy
                  ? () => _openActions(context, controller, en)
                  : null,
              child: SizedBox.square(
                dimension: _size,
                child: Stack(
                  children: [
                    ClipOval(
                      child: SizedBox(
                        key: const ValueKey('profile-photo-image'),
                        width: _size,
                        height: _size,
                        child: avatar == null
                            ? ColoredBox(
                                color: CupertinoColors.activeBlue.withValues(
                                  alpha: .1,
                                ),
                                child: const Icon(
                                  CupertinoIcons.person_fill,
                                  size: 46,
                                  color: CupertinoColors.activeBlue,
                                ),
                              )
                            : Image.memory(
                                avatar.jpeg,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) => const Icon(
                                  CupertinoIcons.person_fill,
                                  size: 46,
                                ),
                              ),
                      ),
                    ),
                    if (controller.busy)
                      const Positioned.fill(
                        child: Center(child: CupertinoActivityIndicator()),
                      )
                    else
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: CupertinoColors.activeBlue.resolveFrom(
                              context,
                            ),
                            border: Border.all(color: background, width: 2.5),
                          ),
                          child: const Icon(
                            CupertinoIcons.camera_fill,
                            size: 14,
                            color: CupertinoColors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (controller.error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                switch (controller.error) {
                  'photo_permission' =>
                    en
                        ? 'Photo access was denied. Allow access in Settings, then try again.'
                        : '未获得照片访问权限，请在系统设置中允许后重试。',
                  'photo_invalid' =>
                    en
                        ? 'This photo could not be processed. Choose a different image.'
                        : '这张照片无法处理，请选择另一张图片。',
                  _ =>
                    en
                        ? 'Photo could not be loaded or saved. Check your connection and retry.'
                        : '头像读取或保存失败，请检查网络后重试。',
                },
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.destructiveRed,
                ),
              ),
            ),
            CupertinoButton(
              onPressed: controller.busy ? null : controller.refresh,
              child: Text(en ? 'Reload photo' : '重新读取头像'),
            ),
          ],
        ],
      ),
    );
  }
}
