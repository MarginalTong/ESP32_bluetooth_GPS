import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../controllers/avatar_controller.dart';
import '../../l10n/app_text.dart';

class ProfileAvatarEditor extends StatelessWidget {
  const ProfileAvatarEditor({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AvatarController?>();
    if (controller == null) return const SizedBox.shrink();
    final en = AppText.of(context).isEnglish;
    final avatar = controller.avatar;
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Semantics(
            label: en ? 'Profile photo' : '个人头像',
            child: ClipOval(
              child: SizedBox(
                width: 88,
                height: 88,
                child: avatar == null
                    ? ColoredBox(
                        color: CupertinoColors.activeBlue.withValues(alpha: .1),
                        child: const Icon(
                          CupertinoIcons.person_fill,
                          size: 40,
                          color: CupertinoColors.activeBlue,
                        ),
                      )
                    : Image.memory(
                        avatar.jpeg,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) =>
                            const Icon(CupertinoIcons.person_fill, size: 40),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (controller.busy)
            const Padding(
              padding: EdgeInsets.all(14),
              child: CupertinoActivityIndicator(),
            )
          else
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                CupertinoButton(
                  onPressed: controller.canEdit
                      ? () => controller.choose(
                          confirm: (jpeg) async =>
                              await showCupertinoDialog<bool>(
                                context: context,
                                builder: (dialog) => CupertinoAlertDialog(
                                  title: Text(
                                    en ? 'Use this profile photo?' : '使用这个头像？',
                                  ),
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
                                      onPressed: () =>
                                          Navigator.pop(dialog, false),
                                      child: Text(en ? 'Cancel' : '取消'),
                                    ),
                                    CupertinoDialogAction(
                                      onPressed: () =>
                                          Navigator.pop(dialog, true),
                                      child: Text(en ? 'Use photo' : '使用头像'),
                                    ),
                                  ],
                                ),
                              ) ??
                              false,
                        )
                      : null,
                  child: Text(
                    avatar == null
                        ? (en ? 'Choose photo' : '设置头像')
                        : (en ? 'Change photo' : '更换头像'),
                  ),
                ),
                if (avatar != null)
                  CupertinoButton(
                    onPressed: controller.canEdit
                        ? () async {
                            final confirmed = await showCupertinoDialog<bool>(
                              context: context,
                              builder: (dialog) => CupertinoAlertDialog(
                                title: Text(
                                  en ? 'Remove profile photo?' : '移除头像？',
                                ),
                                content: Text(
                                  en
                                      ? 'Your account and rider marker will use the default avatar.'
                                      : '账号与骑友地图将恢复默认头像。',
                                ),
                                actions: [
                                  CupertinoDialogAction(
                                    onPressed: () =>
                                        Navigator.pop(dialog, false),
                                    child: Text(en ? 'Cancel' : '取消'),
                                  ),
                                  CupertinoDialogAction(
                                    isDestructiveAction: true,
                                    onPressed: () =>
                                        Navigator.pop(dialog, true),
                                    child: Text(en ? 'Remove' : '移除'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true) await controller.remove();
                          }
                        : null,
                    child: Text(
                      en ? 'Remove photo' : '移除头像',
                      style: const TextStyle(
                        color: CupertinoColors.destructiveRed,
                      ),
                    ),
                  ),
              ],
            ),
          Text(
            en
                ? 'Your photo is visible to signed-in riders only while you share your location. A small cropped copy is saved; the original photo is not uploaded.'
                : '仅在共享位置时向已登录骑友展示头像。只保存裁剪后的小图，不上传原照片。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
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
