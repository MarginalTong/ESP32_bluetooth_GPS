import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../../controllers/account_controller.dart';
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
    final en = AppText.of(context).isEnglish;
    return Semantics(
      label: account.user == null
          ? (en ? 'Sign in to NAVIO' : '登录 NAVIO 账号')
          : (en ? 'Account and profile' : '账号与个人资料'),
      child: CupertinoButton(
        key: const ValueKey('device-account-button'),
        padding: EdgeInsets.zero,
        minimumSize: const Size(44, 44),
        onPressed: () => Navigator.of(
          context,
        ).push(CupertinoPageRoute<void>(builder: (_) => const AccountPage())),
        child: const ProfileAvatarView(size: 36),
      ),
    );
  }
}
