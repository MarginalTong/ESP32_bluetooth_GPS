import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:provider/provider.dart';
import '../controllers/account_controller.dart';
import '../l10n/app_text.dart';
import 'widgets/google_sign_in_button.dart';
import 'widgets/language_section.dart';
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
  AppText get _text => AppText.of(context);
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
      setState(() => notice = _text.enterValidEmail);
      return;
    }
    if ((form == _AccountForm.register ||
            (form == _AccountForm.recovery && recoverySent)) &&
        (password.text.length < 6 || password.text != repeat.text)) {
      setState(() => notice = _text.passwordRuleError);
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
      setState(() => notice = ok ? _text.requestCompletedCheckEmail : null);
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
              child: Text(_text.cancelAction),
            ),
            CupertinoDialogAction(
              isDestructiveAction: deleting,
              onPressed: !deleting || confirmation.text == 'DELETE'
                  ? () => Navigator.pop(dialog, true)
                  : null,
              child: Text(_text.confirmAction),
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
    'local_changed' => _text.localSettingsChangedDuring,
    'conflict' => _text.cloudDataChangedOn,
    'navigation_active' => _text.finishNavigationBeforeChanging,
    'local' => _text.localDataCouldNot,
    'session' => _text.sessionNeedsAttentionSign,
    'apple_grant_failed' => _text.appleAuthorizationCouldNot,
    'google_unconfigured' => _text.googleSignInNot,
    'google_failed' => _text.googleSignInDid,
    _ => _text.requestFailedCheckCredentials,
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
                label: showPasswords ? _text.hidePassword : _text.showPassword,
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
      _AccountForm.login => _text.welcomeBack,
      _AccountForm.register => _text.createAccountTitle,
      _AccountForm.verify => _text.checkEmail,
      _AccountForm.recovery => _text.resetPassword,
    };
    final subtitle = switch (form) {
      _AccountForm.login => _text.placesPreferencesInOne,
      _AccountForm.register => _text.saveFavouritesMakeNavio,
      _AccountForm.verify => _text.enterVerificationCodeSent,
      _AccountForm.recovery =>
        recoverySent ? _text.enterEmailCodeChoose : _text.resetCodeHint,
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
                    field(email, _text.emailLabel),
                    if (verifying || (recovering && recoverySent))
                      field(code, _text.emailCodeLabel, numeric: true),
                    if (!verifying && (!recovering || recoverySent))
                      field(
                        password,
                        recovering
                            ? _text.newPasswordLabel
                            : _text.passwordLabel,
                        secret: true,
                      ),
                    if (newPassword) ...[
                      field(repeat, _text.repeatPasswordLabel, secret: true),
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: Text(
                          _text.atLeast6Characters,
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
                            _text.forgotPassword,
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
                                _AccountForm.login => _text.signInAction,
                                _AccountForm.register =>
                                  _text.createAccountAction,
                                _AccountForm.verify => _text.verifyEmail,
                                _AccountForm.recovery =>
                                  recoverySent
                                      ? _text.setNewPassword
                                      : _text.sendRecoveryCode,
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
                  _text.orContinueWith,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
                const SizedBox(height: 14),
                if (account.googleAvailable) ...[
                  GoogleSignInButton(
                    label: _text.continueGoogle,
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
                            _text.continueApple,
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
                      creating ? _text.alreadyHaveAccount : _text.newNavio,
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
                        creating ? _text.signInAction : _text.registerAction,
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
                  child: Text(_text.backSignIn),
                ),
              const SizedBox(height: 8),
              Text(
                _text.guestNavigationNeedsNo,
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
        middle: Text(loggedIn ? _text.personalProfile : _text.navioAccount),
      ),
      child: SafeArea(
        child: ListView(
          key: ValueKey('account:$loggedIn'),
          padding: const EdgeInsets.all(20),
          children: [
            if (!account.available) Text(_text.accountServiceNotConfigured),
            if (!account.canModify)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(_text.switchingAccountsCloudRestore),
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
              const ProfileNameHeader(),
              const SizedBox(height: 2),
              Text(
                account.user!.email.isEmpty ? 'Apple ID' : account.user!.email,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 12),
              const SettingsSyncSection(),
              const LanguageSection(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 6),
                child: SectionLabel(_text.accountHeader),
              ),
              CupertinoListSection.insetGrouped(
                margin: EdgeInsets.zero,
                children: [
                  _AccountAction(
                    icon: CupertinoIcons.square_arrow_right,
                    title: _text.signOut,
                    onPressed: canAct ? account.signOut : null,
                  ),
                  if (account.user!.apple)
                    _AccountAction(
                      icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                      title: _text.reauthorizeApple,
                      onPressed: canAct && account.appleAvailable
                          ? account.signInApple
                          : null,
                    ),
                  _AccountAction(
                    icon: CupertinoIcons.trash,
                    title: _text.deleteAccount,
                    destructive: true,
                    onPressed: canAct
                        ? () async {
                            if (await _confirm(
                              _text.deleteNavioAccount,
                              _text.permanentlyDeleteAccountIts,
                              deleting: true,
                            )) {
                              await account.deleteAccount();
                            }
                          }
                        : null,
                  ),
                ],
              ),
            ] else ...[
              if (account.available) _signInForm(account, canAct),
              const LanguageSection(),
            ],
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
