import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:provider/provider.dart';
import '../controllers/account_controller.dart';
import '../controllers/profile_controller.dart';
import '../models/account_profile.dart';
import '../l10n/app_text.dart';
import 'navio_theme.dart';

/// The name is the page's headline; tapping it opens the editor.
class ProfileNameHeader extends StatelessWidget {
  const ProfileNameHeader({super.key});
  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileController?>();
    if (profile == null) return const SizedBox.shrink();
    final text = AppText.of(context);
    final color = CupertinoColors.label.resolveFrom(context);
    return Semantics(
      button: true,
      label: text.editName,
      child: CupertinoButton(
        key: const ValueKey('profile-nickname-row'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        minimumSize: const Size(44, 44),
        onPressed: profile.busy
            ? null
            : profile.profile == null
            ? profile.refresh
            : profile.canEdit
            ? () {
                final initial = profile.profile;
                final actor = context.read<AccountController>().user?.id;
                final generation = profile.accountGeneration;
                if (initial == null || actor == null || !profile.canEdit) {
                  return;
                }
                Navigator.of(context).push(
                  CupertinoPageRoute<void>(
                    builder: (_) => ProfileNamePage(
                      initial: initial,
                      actor: actor,
                      accountGeneration: generation,
                    ),
                  ),
                );
              }
            : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                profile.profile?.displayName ??
                    (profile.busy ? (text.loading) : (text.tapRetry)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.4,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 7),
            if (profile.busy)
              const CupertinoActivityIndicator(radius: 8)
            else
              const Icon(
                Icons.edit_rounded,
                size: 24,
                color: CupertinoColors.activeBlue,
              ),
          ],
        ),
      ),
    );
  }
}

class ProfileNamePage extends StatefulWidget {
  const ProfileNamePage({
    super.key,
    required this.initial,
    required this.actor,
    required this.accountGeneration,
  });
  final AccountProfile initial;
  final String actor;
  final int accountGeneration;
  @override
  State<ProfileNamePage> createState() => _ProfileNamePageState();
}

class _ProfileNamePageState extends State<ProfileNamePage> {
  late final _name = TextEditingController(text: widget.initial.displayName);
  late int _revision = widget.initial.revision;
  String? _validation;
  bool _attemptedSave = false;
  bool _current(ProfileController p) =>
      p.accountGeneration == widget.accountGeneration &&
      context.read<AccountController>().user?.id == widget.actor;
  AppText get _text => AppText.of(context);
  Future<void> _save() async {
    final profile = context.read<ProfileController>();
    if (!_current(profile) || !profile.canEdit) return;
    if (!AccountProfile.validName(_name.text.trim())) {
      setState(() => _validation = 'invalid');
      return;
    }
    setState(() {
      _validation = null;
      _attemptedSave = true;
    });
    final saved = await profile.rename(_name.text, expectedRevision: _revision);
    if (saved && mounted && _current(profile)) Navigator.pop(context);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileController>();
    final current = _current(profile);
    final error = _validation ?? (_attemptedSave ? profile.error : null);
    return NavioPage(
      navigationBar: CupertinoNavigationBar(
        middle: Text(_text.nicknameLabel),
        trailing: profile.busy
            ? const CupertinoActivityIndicator()
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: current && profile.canEdit ? _save : null,
                child: Text(_text.doneAction),
              ),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            CupertinoListSection.insetGrouped(
              header: SectionLabel(_text.nicknameHeader),
              footer: Text(
                _text.nicknameHint,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              children: [
                CupertinoTextField(
                  key: const ValueKey('profile-nickname-field'),
                  controller: _name,
                  autofocus: true,
                  enabled: current && !profile.busy,
                  autocorrect: false,
                  maxLength: 80,
                  textInputAction: TextInputAction.done,
                  placeholder: _text.nicknameLabel,
                  padding: const EdgeInsets.all(16),
                  decoration: null,
                  onChanged: (_) {
                    if (_validation != null) setState(() => _validation = null);
                  },
                  onSubmitted: (_) => _save(),
                ),
              ],
            ),
            if (!current)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Text(_text.accountChangedGoBack),
              )
            else if (error != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Text(
                  switch (error) {
                    'invalid' => _text.nicknameInvalid,
                    'conflict' => _text.nicknameChangedOnAnother,
                    'session' => _text.pleaseSignInAgain,
                    _ => _text.couldNotSaveDraft,
                  },
                  style: const TextStyle(
                    fontSize: 14,
                    color: CupertinoColors.systemRed,
                  ),
                ),
              ),
              if (error == 'conflict')
                CupertinoButton(
                  onPressed: profile.busy
                      ? null
                      : () async {
                          await profile.refresh();
                          if (!mounted ||
                              !_current(profile) ||
                              profile.error != null) {
                            return;
                          }
                          setState(() {
                            _name.text = profile.profile!.displayName;
                            _revision = profile.profile!.revision;
                            _validation = null;
                          });
                        },
                  child: Text(_text.loadLatestName),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
