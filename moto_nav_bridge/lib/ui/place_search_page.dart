import 'dart:async';

import 'package:flutter/material.dart';

import '../models/place_result.dart';
import '../services/apple_maps_service.dart';

class PlaceSearchPage extends StatefulWidget {
  const PlaceSearchPage({super.key});

  @override
  State<PlaceSearchPage> createState() => _PlaceSearchPageState();
}

class _PlaceSearchPageState extends State<PlaceSearchPage> {
  final _controller = TextEditingController();
  final _service = AppleMapsService();
  Timer? _debounce;
  List<PlaceResult> _results = const [];
  List<PlaceSuggestion> _suggestions = const [];
  bool _loading = false;
  bool _resolving = false;
  String? _error;
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
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
          _error = showErrorWhenEmpty ? '没找到匹配地点，换个关键词试试' : null;
        }
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = const [];
        _suggestions = const [];
        _error = showErrorWhenEmpty ? '没找到匹配地点，换个关键词试试' : null;
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
        setState(() => _error = '这个候选没有可导航坐标，换一个试试');
        return;
      }
      Navigator.pop(context, place);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '这个候选没有可导航坐标，换一个试试');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索目的地')),
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
              decoration: const InputDecoration(
                hintText: '输入地点、地址或商家名称',
                prefixIcon: Icon(Icons.search_rounded),
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
                ? const _SearchHint()
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
                            onTap: () => Navigator.pop(context, place),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) {
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
          const Text('想去哪里？'),
          const SizedBox(height: 6),
          Text(
            '例如：悉尼歌剧院、机场、咖啡店',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
