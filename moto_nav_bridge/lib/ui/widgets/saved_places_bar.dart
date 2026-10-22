import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import '../../l10n/app_text.dart';
import '../../models/place_result.dart';
import '../../services/saved_places.dart';
import '../place_search_page.dart';

class SavedPlacesBar extends StatefulWidget {
  const SavedPlacesBar({super.key, required this.onSelected});
  final ValueChanged<PlaceResult> onSelected;
  @override
  State<SavedPlacesBar> createState() => _SavedPlacesBarState();
}

class _SavedPlacesBarState extends State<SavedPlacesBar> {
  final store = SavedPlaces();
  Map<String, PlaceResult> places = {};
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await store.load();
      if (mounted) setState(() => places = result);
    } catch (_) {
      if (mounted) setState(() => error = 'load');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit(String slot) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final place = await Navigator.of(context).push<PlaceResult>(
          MaterialPageRoute(builder: (_) => const PlaceSearchPage()));
      if (place == null || !mounted) return;
      await store.save(slot, place);
      if (mounted) {
        setState(() {
          places[slot] = place;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'save');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final en = AppText.of(context).isEnglish;
    final names = en ? ['Home', 'Work', 'School'] : ['家', '公司', '学校'];
    return Column(children: [
      CupertinoListSection.insetGrouped(children: [
        for (var i = 0; i < SavedPlaces.slots.length; i++)
          CupertinoListTile(
            leading: Icon(
                [
                  CupertinoIcons.house,
                  CupertinoIcons.briefcase,
                  CupertinoIcons.book,
                ][i],
                color: CupertinoColors.activeBlue),
            title: Text(names[i]),
            subtitle: Text(
              places[SavedPlaces.slots[i]]?.name ?? (en ? 'Not set' : '未设置'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: busy
                ? null
                : () {
                    final place = places[SavedPlaces.slots[i]];
                    if (place == null) {
                      edit(SavedPlaces.slots[i]);
                    } else {
                      widget.onSelected(place);
                    }
                  },
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: busy ? null : () => edit(SavedPlaces.slots[i]),
              child: Text(en ? 'Edit' : '修改'),
            ),
          ),
      ]),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(en
              ? 'Could not load or save address. Please try again.'
              : '地址读取或保存失败，请重试。'),
        ),
    ]);
  }
}
