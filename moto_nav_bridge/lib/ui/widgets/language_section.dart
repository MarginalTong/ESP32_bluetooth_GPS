import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_text.dart';
import '../../services/settings_store.dart';
import '../navio_theme.dart';

/// Saved with the account settings, so a signed-in choice follows the account.
class LanguageSection extends StatelessWidget {
  const LanguageSection({super.key});

  String _name(AppLanguage language, AppText text) => switch (language) {
    AppLanguage.system => text.followSystem,
    AppLanguage.en => 'English',
    // Each language is named in itself, whatever the current UI language.
    AppLanguage.zh => '简体中文',
  };

  Future<void> _choose(BuildContext context, AppText text) async {
    final choice = await showCupertinoModalPopup<AppLanguage>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(text.languageLabel),
        actions: [
          for (final language in AppLanguage.values)
            CupertinoActionSheetAction(
              isDefaultAction: language == AppText.selected.value,
              onPressed: () => Navigator.pop(sheet, language),
              child: Text(_name(language, text)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: Text(text.cancelAction),
        ),
      ),
    );
    if (choice == null) return;
    AppText.selected.value = choice;
    final preferences = await SharedPreferences.getInstance();
    await SettingsStore.edit(preferences, () async {
      await preferences.setString(AppLanguage.storageKey, choice.name);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
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
                  text.languageLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _name(AppText.selected.value, text),
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
          onTap: () => _choose(context, text),
        ),
      ],
    );
  }
}
