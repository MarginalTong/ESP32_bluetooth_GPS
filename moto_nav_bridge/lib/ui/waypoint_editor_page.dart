import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../l10n/app_text.dart';
import '../models/place_result.dart';
import '../services/waypoint_plan.dart';
import 'place_search_page.dart';

/// Draft-only editor. Back discards edits; Done replaces the trip atomically.
class WaypointEditorPage extends StatefulWidget {
  const WaypointEditorPage({
    super.key,
    required this.destination,
    required this.stops,
    this.choosePlace,
  });
  final PlaceResult destination;
  final List<PlaceResult> stops;
  final Future<PlaceResult?> Function(BuildContext)? choosePlace;
  @override
  State<WaypointEditorPage> createState() => _WaypointEditorPageState();
}

class _WaypointEditorPageState extends State<WaypointEditorPage> {
  late final _stops = List<PlaceResult>.of(widget.stops);
  bool _choosing = false;
  AppText get _text => AppText.of(context);

  Future<void> _choose([int? index]) async {
    if (_choosing) return;
    setState(() => _choosing = true);
    final result =
        await (widget.choosePlace?.call(context) ??
            Navigator.of(context).push<PlaceResult>(
              MaterialPageRoute(builder: (_) => const PlaceSearchPage()),
            ));
    if (!mounted) return;
    setState(() => _choosing = false);
    if (result == null) return;
    if (result.location.distanceTo(widget.destination.location) < 10 ||
        _stops.asMap().entries.any(
          (e) =>
              e.key != index &&
              e.value.location.distanceTo(result.location) < 10,
        )) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_text.chooseDifferentPlaceStop)));
      return;
    }
    setState(() {
      if (index == null) {
        _stops.add(result);
      } else {
        _stops[index] = result;
      }
    });
  }

  void _move(int index, int delta) => setState(() {
    final place = _stops.removeAt(index);
    _stops.insert(index + delta, place);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_text.tripStops),
      leading: CupertinoNavigationBarBackButton(
        onPressed: () => Navigator.maybePop(context),
      ),
      actions: [
        TextButton(
          onPressed: _choosing
              ? null
              : () => Navigator.pop(
                  context,
                  List<PlaceResult>.unmodifiable(_stops),
                ),
          child: Text(_text.doneAction),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          _text.placesVisitedInOrder,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.my_location),
          title: Text(_text.currentLocation),
        ),
        for (var i = 0; i < _stops.length; i++)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 5),
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    key: ValueKey('waypoint-$i'),
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: .1),
                      foregroundColor: Theme.of(context).colorScheme.primary,
                      child: Text('${i + 1}'),
                    ),
                    title: Text(
                      _stops[i].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _stops[i].address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: _choosing ? null : () => _choose(i),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: _text.moveUp,
                        onPressed: !_choosing && i > 0
                            ? () => _move(i, -1)
                            : null,
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        tooltip: _text.moveDown,
                        onPressed: !_choosing && i + 1 < _stops.length
                            ? () => _move(i, 1)
                            : null,
                        icon: const Icon(Icons.arrow_downward),
                      ),
                      IconButton(
                        tooltip: _text.removeStop,
                        onPressed: _choosing
                            ? null
                            : () => setState(() => _stops.removeAt(i)),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: !_choosing && _stops.length < WaypointPlan.maxStops
              ? () => _choose()
              : null,
          icon: const Icon(Icons.add_location_alt_outlined),
          label: Text(_text.addStop(_stops.length, WaypointPlan.maxStops)),
        ),
        ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: Text(widget.destination.name),
          subtitle: Text(_text.finalDestination),
        ),
        if (_stops.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              _text.alternativeRoutesUnavailableTrips,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    ),
  );
}
