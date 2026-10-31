import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:provider/provider.dart';
import '../controllers/account_controller.dart';
import '../l10n/app_text.dart';
import 'widgets/google_sign_in_button.dart';
import 'widgets/profile_avatar_editor.dart';
import 'widgets/settings_sync_section.dart';
import 'navio_theme.dart';
import 'profile_name_page.dart';

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
  bool showPasswords = false;
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
      setState(
        () => notice = t(
          'Use at least 6 characters and matching passwords.',
          '密码至少 6 位，两次输入需一致。',
        ),
      );
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
          ok = await account.resetPassword(
            email.text,
            code.text,
            password.text,
          );
        } else {
          ok = await account.sendRecovery(email.text);
          if (ok && mounted) setState(() => recoverySent = true);
        }
    }
    if (!mounted) return;
    password.clear();
    repeat.clear();
    code.clear();
    if (mounted) {
      setState(
        () => notice = ok
            ? t(
                'Request completed. Check your email if a code is required.',
                '操作已完成，如需验证码请查收邮件。',
              )
            : null,
      );
    }
  }

  Future<bool> _confirm(
    String title,
    String details, {
    bool deleting = false,
  }) async {
    final confirmation = TextEditingController();
    final result = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => CupertinoAlertDialog(
          title: Text(title),
          content: Column(
            children: [
              Text(details),
              if (deleting)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: CupertinoTextField(
                    controller: confirmation,
                    placeholder: 'DELETE',
                    autocorrect: false,
                    onChanged: (_) => update(() {}),
                  ),
                ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(t('Cancel', '取消')),
            ),
            CupertinoDialogAction(
              isDestructiveAction: deleting,
              onPressed: !deleting || confirmation.text == 'DELETE'
                  ? () => Navigator.pop(dialog, true)
                  : null,
              child: Text(t('Confirm', '确认')),
            ),
          ],
        ),
      ),
    );
    // The dialog's text field may still be finishing its exit transition.
    Future<void>.delayed(
      const Duration(milliseconds: 400),
      confirmation.dispose,
    );
    return result == true;
  }

  String _error(String? value) => switch (value) {
    'local_changed' => t(
      'Local settings changed during sync. Nothing was replaced; try again.',
      '同步期间本机资料被修改，未覆盖任何资料，请重试。',
    ),
    'conflict' => t(
      'Cloud data changed on another device. Restore it before uploading.',
      '另一台设备已更新云端资料，请先恢复云端资料，再上传。',
    ),
    'navigation_active' => t(
      'Finish navigation before changing account data.',
      '请先结束导航，再更改账号资料。',
    ),
    'local' => t(
      'Local data could not be saved. Please try again.',
      '本机资料保存失败，请重试。',
    ),
    'session' => t(
      'Your session needs attention. Sign in again.',
      '登录状态已失效，请重新登录。',
    ),
    'apple_grant_failed' => t(
      'Apple authorization could not be saved. Try Apple sign-in again.',
      'Apple 授权保存失败，请重新使用 Apple 登录。',
    ),
    'google_unconfigured' => t(
      'Google sign-in is not configured for this build. Use email for now.',
      '此版本尚未配置好 Google 登录，请暂时使用邮箱登录。',
    ),
    'google_failed' => t(
      'Google sign-in did not complete. Check your connection and try again.',
      'Google 登录未完成，请检查网络后重试。',
    ),
    _ => t(
      'Request failed. Check your credentials, code and connection, then retry.',
      '操作失败，请检查邮箱、密码、验证码或网络后重试。',
    ),
  };
  void _changeForm(_AccountForm value) {
    setState(() {
      form = value;
      recoverySent = false;
      showPasswords = false;
      notice = null;
      password.clear();
      repeat.clear();
      code.clear();
    });
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: CupertinoTextField(
      controller: controller,
      placeholder: label,
      obscureText: secret && !showPasswords,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.none,
      autofillHints: numeric
          ? const [AutofillHints.oneTimeCode]
          : secret
          ? [
              form == _AccountForm.login
                  ? AutofillHints.password
                  : AutofillHints.newPassword,
            ]
          : const [AutofillHints.email],
      prefix: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Icon(
          numeric
              ? CupertinoIcons.number
              : secret
              ? CupertinoIcons.lock
              : CupertinoIcons.mail,
          size: 19,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
      suffix: secret && controller == password
          ? CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              onPressed: context.read<AccountController>().busy
                  ? null
                  : () => setState(() => showPasswords = !showPasswords),
              child: Semantics(
                label: showPasswords
                    ? t('Hide password', '隐藏密码')
                    : t('Show password', '显示密码'),
                child: Icon(
                  showPasswords ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                  size: 20,
                ),
              ),
            )
          : null,
      keyboardType: secret
          ? TextInputType.visiblePassword
          : numeric
          ? TextInputType.number
          : TextInputType.emailAddress,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
        borderRadius: BorderRadius.circular(14),
      ),
      enabled: !context.read<AccountController>().busy,
    ),
  );

  Widget _signInForm(AccountController account, bool canAct) {
    final creating = form == _AccountForm.register;
    final verifying = form == _AccountForm.verify;
    final recovering = form == _AccountForm.recovery;
    final newPassword = creating || (recovering && recoverySent);
    final title = switch (form) {
      _AccountForm.login => t('Welcome back', '欢迎回来'),
      _AccountForm.register => t('Create your account', '创建你的账号'),
      _AccountForm.verify => t('Check your email', '查收验证邮件'),
      _AccountForm.recovery => t('Reset your password', '重置密码'),
    };
    final subtitle = switch (form) {
      _AccountForm.login => t(
        'Your places and preferences, in one place.',
        '登录后，管理你的常用地址与偏好。',
      ),
      _AccountForm.register => t(
        'Save your favourites. Make NAVIO yours.',
        '收藏常用地址，让 NAVIO 更懂你的出行。',
      ),
      _AccountForm.verify => t(
        'Enter the verification code sent to your email.',
        '输入邮件中的验证码，完成账号注册。',
      ),
      _AccountForm.recovery =>
        recoverySent
            ? t(
                'Enter your email code and choose a new password.',
                '输入邮件验证码，并设置新密码。',
              )
            : t(
                'We’ll email you a code to reset your password.',
                '我们将向你的邮箱发送密码重置验证码。',
              ),
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: CupertinoColors.activeBlue.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(
                    CupertinoIcons.location_north_fill,
                    size: 30,
                    color: CupertinoColors.activeBlue,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'NAVIO',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.8,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.45,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: CupertinoColors.secondarySystemGroupedBackground
                      .resolveFrom(context),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field(email, t('Email', '邮箱')),
                    if (verifying || (recovering && recoverySent))
                      field(code, t('Code from email', '邮件验证码'), numeric: true),
                    if (!verifying && (!recovering || recoverySent))
                      field(
                        password,
                        recovering
                            ? t('New password', '新密码')
                            : t('Password', '密码'),
                        secret: true,
                      ),
                    if (newPassword) ...[
                      field(
                        repeat,
                        t('Repeat password', '再次输入密码'),
                        secret: true,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: Text(
                          t(
                            'At least 6 characters. A longer, unique password is safer.',
                            '至少 6 位，建议使用更长且不重复的密码。',
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (form == _AccountForm.login)
                      Align(
                        alignment: Alignment.centerRight,
                        child: CupertinoButton(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          onPressed: canAct
                              ? () => _changeForm(_AccountForm.recovery)
                              : null,
                          child: Text(
                            t('Forgot password?', '忘记密码？'),
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ),
                    if (notice != null || account.error != null)
                      Semantics(
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text(
                            notice ?? _error(account.error),
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: notice != null
                                  ? CupertinoColors.secondaryLabel.resolveFrom(
                                      context,
                                    )
                                  : CupertinoColors.destructiveRed,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    CupertinoButton.filled(
                      borderRadius: BorderRadius.circular(14),
                      onPressed: canAct ? () => _submit(account) : null,
                      child: account.busy
                          ? const CupertinoActivityIndicator()
                          : Text(
                              switch (form) {
                                _AccountForm.login => t('Sign in', '登录'),
                                _AccountForm.register => t(
                                  'Create account',
                                  '创建账号',
                                ),
                                _AccountForm.verify => t(
                                  'Verify email',
                                  '验证邮箱',
                                ),
                                _AccountForm.recovery =>
                                  recoverySent
                                      ? t('Set new password', '设置新密码')
                                      : t('Send recovery code', '发送重置验证码'),
                              },
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              if ((account.appleAvailable || account.googleAvailable) &&
                  (creating || form == _AccountForm.login)) ...[
                const SizedBox(height: 22),
                Text(
                  t('or continue with', '或通过以下方式继续'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 14),
                if (account.googleAvailable) ...[
                  GoogleSignInButton(
                    label: t('Continue with Google', '通过 Google 继续'),
                    onPressed: canAct
                        ? () async {
                            setState(() => notice = null);
                            FocusScope.of(context).unfocus();
                            password.clear();
                            repeat.clear();
                            code.clear();
                            await account.signInGoogle();
                          }
                        : null,
                  ),
                  if (account.appleAvailable) const SizedBox(height: 12),
                ],
                if (account.appleAvailable)
                  CupertinoButton(
                    color: CupertinoColors.label.resolveFrom(context),
                    borderRadius: BorderRadius.circular(14),
                    onPressed: canAct ? account.signInApple : null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.apple,
                          color: CupertinoColors.systemBackground.resolveFrom(
                            context,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            t('Continue with Apple', '通过 Apple 继续'),
                            style: TextStyle(
                              color: CupertinoColors.systemBackground
                                  .resolveFrom(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 14),
              if (form == _AccountForm.login || creating)
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      creating
                          ? t('Already have an account?', '已有账号？')
                          : t('New to NAVIO?', '第一次使用 NAVIO？'),
                      style: TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      onPressed: canAct
                          ? () => _changeForm(
                              creating
                                  ? _AccountForm.login
                                  : _AccountForm.register,
                            )
                          : null,
                      child: Text(
                        creating ? t('Sign in', '登录') : t('Register', '注册'),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                )
              else
                CupertinoButton(
                  onPressed: canAct
                      ? () => _changeForm(_AccountForm.login)
                      : null,
                  child: Text(t('Back to sign in', '返回登录')),
                ),
              const SizedBox(height: 8),
              Text(
                t(
                  'Guest navigation needs no account. When signed in, your saved places and preferences sync automatically; guest settings remain separate.',
                  '游客导航无需账号。登录后常用地址与偏好自动同步，游客资料独立保留。',
                ),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountController>();
    final canAct = account.available && account.ready;
    final loggedIn = account.user != null;
    return NavioPage(
      navigationBar: CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        middle: Text(
          loggedIn
              ? t('Personal profile', '个人资料')
              : t('NAVIO Account', 'NAVIO 账号'),
        ),
      ),
      child: SafeArea(
        child: ListView(
          key: ValueKey('account:$loggedIn'),
          padding: const EdgeInsets.all(20),
          children: [
            if (!account.available)
              Text(
                t(
                  'Account service is not configured in this build. Maps and Bluetooth still work.',
                  '此版本尚未配置账号服务，地图与蓝牙仍可正常使用。',
                ),
              ),
            if (!account.canModify)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  t(
                    'Switching accounts and cloud restore are paused during navigation.',
                    '导航期间暂不切换账号或恢复云端资料。',
                  ),
                ),
              ),
            if (account.busy && loggedIn)
              const Center(child: CupertinoActivityIndicator()),
            if (account.error != null && loggedIn)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error(account.error),
                  style: const TextStyle(color: CupertinoColors.destructiveRed),
                ),
              ),
            if (notice != null && loggedIn)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(notice!),
              ),
            if (loggedIn) ...[
              const ProfileAvatarEditor(),
              CupertinoListSection.insetGrouped(
                margin: EdgeInsets.zero,
                children: [
                  const ProfileNameTile(),
                  CupertinoListTile(
                    title: Text(
                      account.user!.email.isEmpty
                          ? 'Apple ID'
                          : account.user!.email,
                    ),
                    subtitle: Text(
                      t(
                        'Signed in · display pairing stays on this phone',
                        '已登录 · 小屏配对仍保存在本机',
                      ),
                    ),
                  ),
                ],
              ),
              const ProfilePhotoPrivacyNote(),
              const SettingsSyncSection(),
              CupertinoListSection.insetGrouped(
                margin: const EdgeInsets.only(top: 24),
                header: SectionLabel(t('ACCOUNT', '账号')),
                children: [
                  _AccountAction(
                    icon: CupertinoIcons.square_arrow_right,
                    title: t('Sign out', '退出登录'),
                    onPressed: canAct ? account.signOut : null,
                  ),
                  if (account.user!.apple)
                    _AccountAction(
                      icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                      title: t('Reauthorize Apple', '重新验证 Apple 授权'),
                      onPressed: canAct && account.appleAvailable
                          ? account.signInApple
                          : null,
                    ),
                  _AccountAction(
                    icon: CupertinoIcons.trash,
                    title: t('Delete account', '删除账号'),
                    destructive: true,
                    onPressed: canAct
                        ? () async {
                            if (await _confirm(
                              t('Delete NAVIO account?', '删除 NAVIO 账号？'),
                              t(
                                'Permanently delete your account and its cloud addresses/preferences. Type DELETE. Guest data and Bluetooth pairing are separate.',
                                '永久删除账号及其云端地址与偏好。输入 DELETE 确认。游客资料和蓝牙配对独立保留。',
                              ),
                              deleting: true,
                            )) {
                              await account.deleteAccount();
                            }
                          }
                        : null,
                  ),
                ],
              ),
            ] else if (account.available)
              _signInForm(account, canAct),
          ],
        ),
      ),
    );
  }
}

class _AccountAction extends StatelessWidget {
  const _AccountAction({
    required this.icon,
    required this.title,
    this.onPressed,
    this.destructive = false,
  });
  final IconData icon;
  final String title;
  final VoidCallback? onPressed;
  final bool destructive;
  @override
  Widget build(BuildContext context) => CupertinoListTile(
    leading: SettingsIcon(
      icon,
      color: destructive
          ? CupertinoColors.systemRed
          : CupertinoColors.systemBlue,
    ),
    title: Text(
      title,
      style: TextStyle(
        fontSize: 16,
        color: onPressed == null
            ? CupertinoColors.tertiaryLabel.resolveFrom(context)
            : destructive
            ? CupertinoColors.systemRed
            : CupertinoColors.label.resolveFrom(context),
      ),
    ),
    trailing: const CupertinoListTileChevron(),
    onTap: onPressed,
  );
}
