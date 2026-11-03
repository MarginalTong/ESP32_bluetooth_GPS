import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../l10n/app_text.dart';
import '../models/place_result.dart';
import '../services/apple_maps_service.dart';
import '../services/saved_places.dart';
import '../services/search_history_service.dart';
import '../services/location_link_parser.dart';

class PlaceSearchPage extends StatefulWidget {
  const PlaceSearchPage({super.key, this.initialQuery, this.onSavedPlace});
  final String? initialQuery;

  /// When set, saved places appear under the search box. It is called just
  /// before the chosen place is returned, so the caller can start right away.
  final ValueChanged<PlaceResult>? onSavedPlace;

  @override
  State<PlaceSearchPage> createState() => _PlaceSearchPageState();
}

class _PlaceSearchPageState extends State<PlaceSearchPage> {
  final _controller = TextEditingController();
  final _searchFocus = FocusNode(canRequestFocus: false);
  Animation<double>? _entrance;
  bool _initialFocusRequested = false;
  final _service = AppleMapsService();
  final _historyService = SearchHistoryService();
  Timer? _debounce;
  List<PlaceResult> _results = const [];
  List<PlaceSuggestion> _suggestions = const [];
  List<PlaceResult> _history = const [];
  bool _loading = false;
  bool _resolving = false;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    final initial = widget.initialQuery?.trim();
    if (initial != null && initial.isNotEmpty) {
      _controller.text = initial;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(initial);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (_entrance != animation) {
      _entrance?.removeStatusListener(_onTransition);
      _entrance = animation;
      _entrance?.addStatusListener(_onTransition);
    }
    if (animation == null || animation.status == AnimationStatus.completed) {
      _focusAfterEntrance();
    }
  }

  void _onTransition(AnimationStatus status) {
    if (status == AnimationStatus.completed) _focusAfterEntrance();
  }

  void _focusAfterEntrance() {
    if (ModalRoute.of(context)?.offstage ?? false) return;
    if (_initialFocusRequested) return;
    _initialFocusRequested = true;
    // Avoid keyboard layout work while the map and search page are sliding.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        _searchFocus.canRequestFocus = true;
        _searchFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _entrance?.removeStatusListener(_onTransition);
    _searchFocus.dispose();
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await _historyService.load();
      if (!mounted) return;
      setState(() => _history = history);
    } catch (_) {
      // History is a convenience feature. Search must still work if local
      // storage is unavailable or the platform channel fails.
    }
  }

  void _changed(String value) {
    _debounce?.cancel();
    ++_requestId;
    setState(() {
      _results = const [];
      _suggestions = const [];
      _error = null;
    });
    if (value.trim().isEmpty) {
      setState(() {
        _results = const [];
        _suggestions = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => _complete(value),
    );
  }

  Future<void> _complete(String value) async {
    if (LocationLinkParser.accepts(value)) {
      await _search(value);
      return;
    }
    final id = ++_requestId;
    final query = value.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final suggestions = await _service.complete(query);
      if (!mounted || id != _requestId) return;
      if (suggestions.isEmpty) {
        await _searchExact(query, id, showErrorWhenEmpty: false);
        return;
      }
      setState(() {
        _suggestions = suggestions;
        _results = const [];
      });
    } catch (_) {
      if (!mounted || id != _requestId) return;
      await _searchExact(query, id, showErrorWhenEmpty: false);
    } finally {
      if (mounted && id == _requestId) setState(() => _loading = false);
    }
  }

  Future<void> _search(String value) async {
    _debounce?.cancel();
    final id = ++_requestId;
    final query = value.trim();
    setState(() {
      _loading = true;
      _error = null;
    });
    await _searchExact(query, id, showErrorWhenEmpty: true);
    if (mounted && id == _requestId) setState(() => _loading = false);
  }

  Future<void> _searchExact(
    String query,
    int id, {
    required bool showErrorWhenEmpty,
  }) async {
    if (query.isEmpty) return;
    try {
      final results = LocationLinkParser.accepts(query)
          ? await LocationLinkParser(geocode: _service.search).parse(query)
          : await _service.search(query);
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = results;
        _suggestions = const [];
        if (results.isEmpty) {
          _error = showErrorWhenEmpty
              ? AppText.of(context).noMatchingPlaces
              : null;
        }
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = const [];
        _suggestions = const [];
        final text = AppText.of(context);
        _error = LocationLinkParser.accepts(query)
            ? (text.couldNotResolveLocation)
            : (showErrorWhenEmpty
                  ? AppText.of(context).noMatchingPlaces
                  : null);
      });
    }
  }

  Future<void> _selectSuggestion(PlaceSuggestion suggestion) async {
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      final place = await _service.resolveSuggestion(suggestion);
      if (!mounted) return;
      if (place == null) {
        setState(() => _error = AppText.of(context).candidateHasNoCoordinate);
        return;
      }
      await _selectPlace(place);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = AppText.of(context).candidateHasNoCoordinate);
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _selectPlace(PlaceResult place) async {
    if (place.resolutionStatus != null) {
      final text = AppText.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(text.confirmDestination),
          content: Text(
            '${place.name}\n${place.address}\n\n${place.resolutionStatus == 'viewport' ? (text.mapViewCentreNot) : (text.checkDestinationOnMap)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(text.cancelAction),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(text.showOnMap),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    try {
      await _historyService.save(place);
    } catch (_) {
      // Do not block navigation just because history persistence failed.
    }
    if (mounted) Navigator.pop(context, place);
  }

  Future<void> _clearHistory() async {
    try {
      await _historyService.clear();
    } catch (_) {
      // Ignore storage failures; still clear the current page state.
    }
    if (mounted) setState(() => _history = const []);
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Text(text.searchDestination),
        leading: CupertinoNavigationBarBackButton(
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: Column(
        children: [
          Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _controller,
              focusNode: _searchFocus,
              onChanged: _changed,
              onSubmitted: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: text.enterPlaceAddressBusiness,
                prefixIcon: Icon(
                  CupertinoIcons.search,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                suffixIcon: IconButton(
                  tooltip: text.pasteLocationLink,
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (!mounted || data?.text == null) return;
                    _controller.text = data!.text!;
                    _changed(data.text!);
                  },
                ),
              ),
            ),
          ),
          if (widget.onSavedPlace != null && _controller.text.isEmpty)
            _SavedPlaceShortcuts(
              onSelect: (place) {
                widget.onSavedPlace!(place);
                Navigator.of(context).pop(place);
              },
            ),
          if (_loading || _resolving)
            const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child:
                _results.isEmpty &&
                    _suggestions.isEmpty &&
                    !_loading &&
                    _error == null
                ? _history.isEmpty
                      ? const _SearchHint()
                      : _SearchHistoryList(
                          places: _history,
                          onSelect: _selectPlace,
                          onClear: _clearHistory,
                        )
                : _suggestions.isNotEmpty
                ? ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final suggestion = _suggestions[index];
                      return ListTile(
                        leading: const _PlaceIcon(CupertinoIcons.search),
                        title: Text(suggestion.title),
                        subtitle: suggestion.subtitle.isEmpty
                            ? null
                            : Text(
                                suggestion.subtitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _resolving
                            ? null
                            : () => _selectSuggestion(suggestion),
                      );
                    },
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final place = _results[index];
                      return ListTile(
                        leading: const _PlaceIcon(CupertinoIcons.map_pin),
                        title: Text(place.name),
                        subtitle: Text(
                          place.address,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _selectPlace(place),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// One tap on a saved place starts the trip; an unset one is set up first.
class _SavedPlaceShortcuts extends StatefulWidget {
  const _SavedPlaceShortcuts({required this.onSelect});
  final ValueChanged<PlaceResult> onSelect;
  @override
  State<_SavedPlaceShortcuts> createState() => _SavedPlaceShortcutsState();
}

class _SavedPlaceShortcutsState extends State<_SavedPlaceShortcuts> {
  final _store = SavedPlaces();
  Map<String, PlaceResult> _places = const {};

  @override
  void initState() {
    super.initState();
    _store.load().then((places) {
      if (mounted) setState(() => _places = places);
    });
  }

  Future<void> _setUp(String slot) async {
    final place = await Navigator.of(context).push<PlaceResult>(
      MaterialPageRoute(builder: (_) => const PlaceSearchPage()),
    );
    if (place == null || !mounted) return;
    try {
      await _store.save(slot, place);
    } catch (_) {
      return; // Unsaved: the slot keeps offering to be set up.
    }
    if (mounted) setState(() => _places = {..._places, slot: place});
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final labels = text.savedPlaceLabels;
    const icons = [
      CupertinoIcons.house_fill,
      CupertinoIcons.briefcase_fill,
      CupertinoIcons.book_fill,
    ];
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: Row(
        children: [
          for (var i = 0; i < SavedPlaces.slots.length; i++)
            Expanded(
              child: _SavedPlaceButton(
                key: ValueKey('saved-place-${SavedPlaces.slots[i]}'),
                icon: icons[i],
                label: labels[i],
                detail: _places[SavedPlaces.slots[i]]?.name ?? (text.addAction),
                set: _places[SavedPlaces.slots[i]] != null,
                onTap: () {
                  final place = _places[SavedPlaces.slots[i]];
                  if (place == null) {
                    _setUp(SavedPlaces.slots[i]);
                  } else {
                    widget.onSelect(place);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _SavedPlaceButton extends StatelessWidget {
  const _SavedPlaceButton({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    required this.set,
    required this.onTap,
  });
  final IconData icon;
  final String label, detail;
  final bool set;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: set
                    ? colors.primary
                    : colors.primary.withValues(alpha: .1),
              ),
              child: Icon(
                set ? icon : CupertinoIcons.plus,
                size: 20,
                color: set ? colors.onPrimary : colors.primary,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchHistoryList extends StatelessWidget {
  const _SearchHistoryList({
    required this.places,
    required this.onSelect,
    required this.onClear,
  });

  final List<PlaceResult> places;
  final ValueChanged<PlaceResult> onSelect;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: places.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text.recentSearches,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                TextButton(onPressed: onClear, child: Text(text.clear)),
              ],
            ),
          );
        }

        final place = places[index - 1];
        return ListTile(
          leading: const _PlaceIcon(CupertinoIcons.clock),
          title: Text(place.name),
          subtitle: place.address.isEmpty
              ? null
              : Text(
                  place.address,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: const Icon(Icons.north_west_rounded),
          onTap: () => onSelect(place),
        );
      },
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PlaceIcon(CupertinoIcons.search, size: 56),
          const SizedBox(height: 14),
          Text(text.whereTo, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              text.searchExamples,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceIcon extends StatelessWidget {
  const _PlaceIcon(this.icon, {this.size = 36});
  final IconData icon;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(size * .28),
    ),
    child: Icon(
      icon,
      size: size * .52,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}
