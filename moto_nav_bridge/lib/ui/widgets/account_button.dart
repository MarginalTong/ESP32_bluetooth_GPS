import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../controllers/account_controller.dart';
import '../../controllers/profile_controller.dart';
import '../../l10n/app_text.dart';
import '../account_page.dart';
import 'profile_avatar_view.dart';

/// Compact account entry; the device page remains dedicated to the display.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key});
  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountController?>();
    if (account == null) return const SizedBox.shrink();
    final text = AppText.of(context);
    final profile = context.watch<ProfileController?>();
    final name = account.user == null ? null : profile?.profile?.displayName;
    return Semantics(
      label: account.user == null ? (text.signInNavio) : (text.accountProfile),
      child: CupertinoButton(
        key: const ValueKey('device-account-button'),
        padding: EdgeInsets.zero,
        minimumSize: const Size(44, 44),
        onPressed: () => Navigator.of(
          context,
        ).push(CupertinoPageRoute<void>(builder: (_) => const AccountPage())),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (account.user != null) ...[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width < 360 ? 82 : 112,
                ),
                child: Text(
                  name ?? (text.profileLabel),
                  key: const ValueKey('device-account-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            const ProfileAvatarView(size: 36),
          ],
        ),
      ),
    );
  }
}
