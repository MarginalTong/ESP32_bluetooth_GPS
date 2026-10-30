import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, Icons;
import 'package:provider/provider.dart';
import '../controllers/account_controller.dart';
import '../l10n/app_text.dart';

enum _AccountForm { login, register, verify, recovery }

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final email = TextEditingController(), password = TextEditingController();
  final code = TextEditingController(), repeat = TextEditingController();
  _AccountForm form = _AccountForm.login;
  bool recoverySent = false;
  String? notice;
  String t(String en, String zh) => AppText.of(context).isEnglish ? en : zh;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    code.dispose();
    repeat.dispose();
    super.dispose();
  }

  Future<void> _submit(AccountController account) async {
    FocusScope.of(context).unfocus();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.text.trim())) {
      setState(() => notice = t('Enter a valid email.', '请输入有效邮箱。'));
      return;
    }
    if ((form == _AccountForm.register ||
            (form == _AccountForm.recovery && recoverySent)) &&
        (password.text.length < 6 || password.text != repeat.text)) {
      setState(() => notice = t(
          'Use at least 6 characters and matching passwords.',
          '密码至少 6 位，两次输入需一致。'));
      return;
    }
    bool ok;
    switch (form) {
      case _AccountForm.login:
        ok = await account.signIn(email.text, password.text);
      case _AccountForm.register:
        ok = await account.register(email.text, password.text);
        if (ok && mounted && account.user == null) {
          setState(() => form = _AccountForm.verify);
        }
      case _AccountForm.verify:
        ok = await account.verifyEmail(email.text, code.text);
      case _AccountForm.recovery:
        if (recoverySent) {
          ok =
              await account.resetPassword(email.text, code.text, password.text);
        } else {
          ok = await account.sendRecovery(email.text);
          if (ok && mounted) setState(() => recoverySent = true);
        }
    }
    password.clear();
    repeat.clear();
    code.clear();
    if (mounted) {
      setState(() => notice = ok
          ? t('Request completed. Check your email if a code is required.',
              '操作已完成，如需验证码请查收邮件。')
          : null);
    }
  }

  Future<bool> _confirm(String title, String details,
      {bool deleting = false}) async {
    final confirmation = TextEditingController();
    final result = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialog) => StatefulBuilder(
            builder: (context, update) => CupertinoAlertDialog(
                    title: Text(title),
                    content: Column(children: [
                      Text(details),
                      if (deleting)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: CupertinoTextField(
                                controller: confirmation,
                                placeholder: 'DELETE',
                                autocorrect: false,
                                onChanged: (_) => update(() {}))),
                    ]),
                    actions: [
                      CupertinoDialogAction(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: Text(t('Cancel', '取消'))),
                      CupertinoDialogAction(
                          isDestructiveAction: deleting,
                          onPressed: !deleting || confirmation.text == 'DELETE'
                              ? () => Navigator.pop(dialog, true)
                              : null,
                          child: Text(t('Confirm', '确认'))),
                    ])));
    // The dialog's text field may still be finishing its exit transition.
    Future<void>.delayed(
        const Duration(milliseconds: 400), confirmation.dispose);
    return result == true;
  }

  String _error(String? value) => switch (value) {
        'local_changed' => t(
            'Local settings changed during sync. Nothing was replaced; try again.',
            '同步期间本机资料被修改，未覆盖任何资料，请重试。'),
        'conflict' => t(
            'Cloud data changed on another device. Restore it before uploading.',
            '另一台设备已更新云端资料，请先恢复云端资料，再上传。'),
        'navigation_active' => t(
            'Finish navigation before changing account data.',
            '请先结束导航，再更改账号资料。'),
        'local' => t('Local data could not be saved. Please try again.',
            '本机资料保存失败，请重试。'),
        'session' =>
          t('Your session needs attention. Sign in again.', '登录状态已失效，请重新登录。'),
        'apple_grant_failed' => t(
            'Apple authorization could not be saved. Try Apple sign-in again.',
            'Apple 授权保存失败，请重新使用 Apple 登录。'),
        _ => t(
            'Request failed. Check your credentials, code and connection, then retry.',
            '操作失败，请检查邮箱、密码、验证码或网络后重试。'),
      };
  Widget field(TextEditingController controller, String label,
          {bool secret = false, bool numeric = false}) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: CupertinoTextField(
            controller: controller,
            placeholder: label,
            obscureText: secret,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: secret
                ? TextInputType.visiblePassword
                : numeric
                    ? TextInputType.number
                    : TextInputType.emailAddress,
            padding: const EdgeInsets.all(15),
            enabled: !context.read<AccountController>().busy,
          ));

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountController>();
    final canAct = account.available && account.ready;
    final loggedIn = account.user != null;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
          transitionBetweenRoutes: false,
          middle: Text(t('NAVIO Account', 'NAVIO 账号'))),
      child: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
        if (!account.available)
          Text(t(
              'Account service is not configured in this build. Maps and Bluetooth still work.',
              '此版本尚未配置账号服务，地图与蓝牙仍可正常使用。')),
        if (!account.canModify)
          Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(t(
                  'Account changes and cloud restore are paused during navigation.',
                  '导航期间暂不切换账号或恢复云端资料。'))),
        if (account.busy) const Center(child: CupertinoActivityIndicator()),
        if (account.error != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_error(account.error),
                  style:
                      const TextStyle(color: CupertinoColors.destructiveRed))),
        if (notice != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(notice!)),
        if (loggedIn) ...[
          CupertinoListSection.insetGrouped(margin: EdgeInsets.zero, children: [
            CupertinoListTile(
                title: Text(account.user!.email.isEmpty
                    ? 'Apple ID'
                    : account.user!.email),
                subtitle: Text(t(
                    'Signed in · display pairing stays on this phone',
                    '已登录 · 小屏配对仍保存在本机'))),
          ]),
          const SizedBox(height: 20),
          Text(t(
              'Cloud sync is manual. Only saved addresses and preferences are included; BLE keys and location history are never uploaded.',
              '云同步由你主动操作，仅包含常用地址和偏好设置，不上传蓝牙密钥或定位轨迹。')),
          const SizedBox(height: 12),
          CupertinoButton.filled(
              onPressed: canAct
                  ? () async {
                      if (await _confirm(
                          t('Upload to NAVIO cloud?', '上传到 NAVIO 云端？'),
                          t('Upload this account’s saved addresses and map/route preferences. This replaces its cloud copy.',
                              '将当前账号的常用地址、地图与路线偏好上传，替换该账号的云端副本。'))) {
                        await account.upload();
                      }
                    }
                  : null,
              child: Text(t('Upload current settings', '上传当前资料'))),
          CupertinoButton(
              onPressed: canAct
                  ? () async {
                      if (await _confirm(
                          t('Restore cloud data?', '恢复云端资料？'),
                          t('Replace this account’s local addresses and preferences with its cloud copy.',
                              '使用云端副本替换当前账号在本机的常用地址与偏好。'))) {
                        await account.download();
                      }
                    }
                  : null,
              child: Text(t('Restore from cloud', '从云端恢复'))),
          CupertinoButton(
              onPressed: canAct
                  ? () async {
                      if (await _confirm(
                          t('Import guest settings?', '导入游客资料？'),
                          t('Copy guest addresses and preferences to this account on this phone. Nothing is uploaded automatically.',
                              '把本机游客地址与偏好复制到当前账号，不会自动上传。'))) {
                        await account.importGuest();
                      }
                    }
                  : null,
              child: Text(t('Import guest settings', '导入游客资料'))),
          if (account.lastSync != null)
            Text(t('Last sync: ', '上次同步：') +
                account.lastSync!.toLocal().toString().split('.').first),
          const SizedBox(height: 20),
          CupertinoButton(
              onPressed: canAct ? account.signOut : null,
              child: Text(t('Sign out', '退出登录'))),
          if (account.user!.apple)
            CupertinoButton(
                onPressed: canAct && account.appleAvailable
                    ? account.signInApple
                    : null,
                child: Text(t('Reauthorize Apple', '重新验证 Apple 授权'))),
          CupertinoButton(
              onPressed: canAct
                  ? () async {
                      if (await _confirm(
                          t('Delete NAVIO account?', '删除 NAVIO 账号？'),
                          t('Permanently delete your account and its cloud addresses/preferences. Type DELETE. Guest data and Bluetooth pairing are separate.',
                              '永久删除账号及其云端地址与偏好。输入 DELETE 确认。游客资料和蓝牙配对独立保留。'),
                          deleting: true)) {
                        await account.deleteAccount();
                      }
                    }
                  : null,
              child: Text(t('Delete account', '删除账号'),
                  style:
                      const TextStyle(color: CupertinoColors.destructiveRed))),
        ] else if (account.available) ...[
          CupertinoSlidingSegmentedControl<_AccountForm>(
              groupValue:
                  form == _AccountForm.register ? form : _AccountForm.login,
              children: {
                _AccountForm.login: Text(t('Sign in', '登录')),
                _AccountForm.register: Text(t('Register', '注册'))
              },
              onValueChanged: (value) {
                if (canAct && value != null) {
                  setState(() {
                    form = value;
                    recoverySent = false;
                    notice = null;
                  });
                }
              }),
          const SizedBox(height: 18),
          field(email, t('Email', '邮箱')),
          if (form == _AccountForm.login ||
              form == _AccountForm.register ||
              recoverySent)
            field(
                password,
                form == _AccountForm.recovery
                    ? t('New password', '新密码')
                    : t('Password', '密码'),
                secret: true),
          if (form == _AccountForm.register ||
              (form == _AccountForm.recovery && recoverySent))
            field(repeat, t('Repeat password', '再次输入密码'), secret: true),
          if (form == _AccountForm.verify ||
              (form == _AccountForm.recovery && recoverySent))
            field(code, t('Code from email', '邮件验证码'), numeric: true),
          const SizedBox(height: 12),
          CupertinoButton.filled(
              onPressed: canAct ? () => _submit(account) : null,
              child: Text(switch (form) {
                _AccountForm.login => t('Sign in', '登录'),
                _AccountForm.register => t('Create account', '创建账号'),
                _AccountForm.verify => t('Verify email', '验证邮箱'),
                _AccountForm.recovery => recoverySent
                    ? t('Set new password', '设置新密码')
                    : t('Send recovery code', '发送重置验证码'),
              })),
          CupertinoButton(
              onPressed: canAct
                  ? () => setState(() {
                        form = _AccountForm.recovery;
                        recoverySent = false;
                        notice = null;
                      })
                  : null,
              child: Text(t('Forgot password?', '忘记密码？'))),
          CupertinoButton(
              color: Colors.black,
              onPressed:
                  canAct && account.appleAvailable ? account.signInApple : null,
              child:
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.apple, color: Colors.white),
                const SizedBox(width: 8),
                Text(t('Continue with Apple', '通过 Apple 继续'),
                    style: const TextStyle(color: Colors.white)),
              ])),
          if (!account.appleAvailable)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                    t('Apple sign-in is pending developer/provider configuration.',
                        'Apple 登录尚待完成开发者与服务端配置。'),
                    style: const TextStyle(fontSize: 12))),
          const SizedBox(height: 18),
          Text(
              t('Supabase processes your email and authentication. Addresses are uploaded only when you choose cloud sync. Guest navigation needs no account.',
                  '邮箱与登录验证由 Supabase 处理。地址仅在你选择云同步时上传；游客导航无需注册账号。'),
              style: const TextStyle(
                  fontSize: 13, color: CupertinoColors.secondaryLabel)),
        ],
      ])),
    );
  }
}
