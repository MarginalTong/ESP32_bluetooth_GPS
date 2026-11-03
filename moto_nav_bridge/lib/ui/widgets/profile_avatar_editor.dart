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
    AppText text,
  ) async {
    final hasPhoto = controller.avatar != null;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        message: Text(text.photoVisibleSignedIn),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheet, 'choose'),
            child: Text(hasPhoto ? (text.changePhoto) : (text.choosePhoto)),
          ),
          if (hasPhoto)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(sheet, 'remove'),
              child: Text(text.removePhoto),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: Text(text.cancelAction),
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'choose') {
      await _choose(context, controller, text);
    } else if (action == 'remove') {
      await _remove(context, controller, text);
    }
  }

  Future<void> _choose(
    BuildContext context,
    AvatarController controller,
    AppText text,
  ) => controller.choose(
    confirm: (jpeg) async =>
        await showCupertinoDialog<bool>(
          context: context,
          builder: (dialog) => CupertinoAlertDialog(
            title: Text(text.useProfilePhoto),
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
                  Text(text.visibleRidersWhenShare),
                ],
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(text.cancelAction),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(text.usePhoto),
              ),
            ],
          ),
        ) ??
        false,
  );

  Future<void> _remove(
    BuildContext context,
    AvatarController controller,
    AppText text,
  ) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(text.removeProfilePhoto),
        content: Text(text.accountRiderMarkerWill),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(text.cancelAction),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(text.removeAction),
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
    final text = AppText.of(context);
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
            label: text.editProfilePhoto,
            child: CupertinoButton(
              key: const ValueKey('profile-photo-button'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(_size, _size),
              onPressed: controller.canEdit && !controller.busy
                  ? () => _openActions(context, controller, text)
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
                  'photo_permission' => text.photoPermissionDenied,
                  'photo_invalid' => text.photoInvalid,
                  _ => text.photoUnavailable,
                },
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.destructiveRed,
                ),
              ),
            ),
            CupertinoButton(
              onPressed: controller.busy ? null : controller.refresh,
              child: Text(text.reloadPhoto),
            ),
          ],
        ],
      ),
    );
  }
}
