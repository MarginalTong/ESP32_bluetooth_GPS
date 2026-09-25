import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_text.dart';
import '../models/place_result.dart';
import '../services/apple_maps_service.dart';
import '../services/search_history_service.dart';

class PlaceSearchPage extends StatefulWidget {
  const PlaceSearchPage({super.key});

  @override
  State<PlaceSearchPage> createState() => _PlaceSearchPageState();
}

class _PlaceSearchPageState extends State<PlaceSearchPage> {
  final _controller = TextEditingController();
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
  }

  @override
  void dispose() {
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
    if (value.trim().isEmpty) {
      setState(() {
        _results = const [];
        _suggestions = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    _debounce =
        Timer(const Duration(milliseconds: 250), () => _complete(value));
  }

  Future<void> _complete(String value) async {
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
      final results = await _service.search(query);
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = results;
        _suggestions = const [];
        if (results.isEmpty) {
          _error =
              showErrorWhenEmpty ? AppText.of(context).noMatchingPlaces : null;
        }
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = const [];
        _suggestions = const [];
        _error =
            showErrorWhenEmpty ? AppText.of(context).noMatchingPlaces : null;
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
      appBar: AppBar(title: Text(text.searchDestination)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _changed,
              onSubmitted: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: text.enterPlaceAddressBusiness,
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
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
            child: _results.isEmpty &&
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
                            leading: const Icon(Icons.search_rounded),
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
                            leading: const Icon(Icons.location_on_outlined),
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
                TextButton(
                  onPressed: onClear,
                  child: Text(text.clear),
                ),
              ],
            ),
          );
        }

        final place = places[index - 1];
        return ListTile(
          leading: const Icon(Icons.history_rounded),
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
          Icon(
            Icons.travel_explore_rounded,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text(text.whereTo),
          const SizedBox(height: 6),
          Text(
            text.searchExamples,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
