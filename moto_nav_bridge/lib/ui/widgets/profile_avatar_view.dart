import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../controllers/avatar_controller.dart';

class ProfileAvatarView extends StatelessWidget {
  const ProfileAvatarView({super.key, this.size = 32});
  final double size;
  @override
  Widget build(BuildContext context) {
    final avatar = context.watch<AvatarController?>()?.avatar;
    final fallback = Icon(
      CupertinoIcons.person_crop_circle_fill,
      size: size,
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: avatar == null
            ? fallback
            : Image.memory(
                avatar.jpeg,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
