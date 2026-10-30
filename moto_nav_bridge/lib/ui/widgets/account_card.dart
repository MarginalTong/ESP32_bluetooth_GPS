import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:provider/provider.dart';
import '../../controllers/account_controller.dart';
import '../../l10n/app_text.dart';
import '../account_page.dart';
import 'profile_avatar_view.dart';

class AccountCard extends StatelessWidget {
  const AccountCard({super.key});
  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountController?>();
    if (account == null) return const SizedBox.shrink();
    final en = AppText.of(context).isEnglish;
    return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: CupertinoListSection.insetGrouped(
          margin: EdgeInsets.zero,
          children: [
            CupertinoListTile(
              leading: const ProfileAvatarView(size: 30),
              title: Text(
                  account.user?.email ?? (en ? 'NAVIO Account' : 'NAVIO 账号'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: Text(account.user != null
                  ? (en ? 'Account and cloud sync' : '账号与云同步')
                  : (en
                      ? 'Sign in or register · guest use still available'
                      : '登录或注册 · 仍可使用游客功能')),
              trailing: const CupertinoListTileChevron(),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const AccountPage())),
            )
          ],
        ));
  }
}
