import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_text.dart';
import '../navio_theme.dart';

/// Device-local: the language is not part of the synced account settings.
class LanguageSection extends StatelessWidget {
  const LanguageSection({super.key});

  String _name(AppLanguage language, bool en) => switch (language) {
    AppLanguage.system => en ? 'Follow system' : '跟随系统',
    AppLanguage.en => 'English',
    AppLanguage.zh => '简体中文',
  };

  Future<void> _choose(BuildContext context, bool en) async {
    final choice = await showCupertinoModalPopup<AppLanguage>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(en ? 'Language' : '语言'),
        actions: [
          for (final language in AppLanguage.values)
            CupertinoActionSheetAction(
              isDefaultAction: language == AppText.selected.value,
              onPressed: () => Navigator.pop(sheet, language),
              child: Text(_name(language, en)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: Text(en ? 'Cancel' : '取消'),
        ),
      ),
    );
    if (choice == null) return;
    AppText.selected.value = choice;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(AppLanguage.storageKey, choice.name);
  }

  @override
  Widget build(BuildContext context) {
    final en = AppText.of(context).isEnglish;
    return CupertinoListSection.insetGrouped(
      margin: const EdgeInsets.only(top: 24),
      children: [
        CupertinoListTile(
          key: const ValueKey('language-row'),
          leading: const SettingsIcon(
            CupertinoIcons.globe,
            color: CupertinoColors.systemIndigo,
          ),
          // A plain additionalInfo overflows on narrow screens with large text.
          title: Row(
            children: [
              Flexible(
                child: Text(
                  en ? 'Language' : '语言',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _name(AppText.selected.value, en),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ],
          ),
          trailing: const CupertinoListTileChevron(),
          onTap: () => _choose(context, en),
        ),
      ],
    );
  }
}
