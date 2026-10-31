import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../controllers/account_controller.dart';
import '../controllers/profile_controller.dart';
import '../models/account_profile.dart';
import '../l10n/app_text.dart';
import 'navio_theme.dart';

class ProfileNameTile extends StatelessWidget {
  const ProfileNameTile({super.key});
  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileController?>();
    if (profile == null) return const SizedBox.shrink();
    final en = AppText.of(context).isEnglish;
    return CupertinoListTile(
      key: const ValueKey('profile-nickname-row'),
      leading: const SettingsIcon(CupertinoIcons.person),
      title: Text(en ? 'Nickname' : '昵称'),
      additionalInfo: Flexible(
        child: Text(
          profile.profile?.displayName ??
              (profile.busy
                  ? (en ? 'Loading…' : '读取中…')
                  : (en ? 'Tap to retry' : '点击重试')),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      trailing: profile.busy
          ? const CupertinoActivityIndicator(radius: 8)
          : const CupertinoListTileChevron(),
      onTap: profile.busy
          ? null
          : profile.profile == null
          ? profile.refresh
          : profile.canEdit
          ? () {
              final initial = profile.profile;
              final actor = context.read<AccountController>().user?.id;
              final generation = profile.accountGeneration;
              if (initial == null || actor == null || !profile.canEdit) return;
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
  String t(String en, String zh) => AppText.of(context).isEnglish ? en : zh;
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
        middle: Text(t('Nickname', '昵称')),
        trailing: profile.busy
            ? const CupertinoActivityIndicator()
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: current && profile.canEdit ? _save : null,
                child: Text(t('Done', '完成')),
              ),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            CupertinoListSection.insetGrouped(
              header: SectionLabel(t('YOUR NICKNAME', '你的昵称')),
              footer: Text(
                t(
                  '1–32 characters. Saved to your account when you finish editing. Nicknames do not need to be unique.',
                  '1–32 个字符，编辑完成后保存到账号。昵称无需唯一。',
                ),
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
                  placeholder: t('Nickname', '昵称'),
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
                child: Text(
                  t(
                    'Your account changed. Go back to your profile before editing.',
                    '账号已切换，请返回个人资料后重新编辑。',
                  ),
                ),
              )
            else if (error != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Text(
                  switch (error) {
                    'invalid' => t(
                      'Use 1–32 characters, without line breaks or hidden control characters.',
                      '请输入 1–32 个字符，不含换行或隐藏控制字符。',
                    ),
                    'conflict' => t(
                      'Your nickname changed on another device. Load the latest name before editing again.',
                      '昵称已在其他设备修改，请读取最新昵称后重新编辑。',
                    ),
                    'session' => t(
                      'Please sign in again before saving.',
                      '请重新登录后保存。',
                    ),
                    _ => t(
                      'Could not save. Your draft is still here; check your connection and try Done again.',
                      '未能保存，输入内容仍保留。请检查网络后重试。',
                    ),
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
                  child: Text(t('Load latest name', '读取最新昵称')),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
