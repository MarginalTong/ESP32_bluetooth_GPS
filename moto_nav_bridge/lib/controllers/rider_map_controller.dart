import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/lat_lng.dart';
import '../models/rider_presence.dart';
import '../services/rider_presence_backend.dart';
import 'navigation_controller.dart';

/// Separate from the GPS/BLE critical path: listeners enqueue cloud work only.
class RiderMapController extends ChangeNotifier {
  RiderMapController(this.backend, {DateTime Function()? now, bool tick = true})
    : _now = now ?? DateTime.now {
    _userId = backend.userId;
    _auth = backend.userChanges.listen((id) {
      if (id == _userId) {
        return;
      }
      _userId = id;
      sharing = viewing = false;
      riders = const [];
      _publishError = _fetchError = null;
      truncated = false;
      _generation++;
      _schedule();
      _notify();
    });
    if (tick) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => pulse());
    }
  }
  final RiderPresenceBackend backend;
  final DateTime Function() _now;
  NavigationController? _nav;
  late final StreamSubscription<String?> _auth;
  Timer? _timer;
  String? _userId, _session;
  bool sharing = false, viewing = false, truncated = false;
  bool _disposed = false, _syncing = false, _dirty = false, _fetching = false;
  bool _foreground = true, _mapVisible = true;
  int _generation = 0, _sequence = 0;
  int _tripGeneration = 0, _sessionTripGeneration = -1;
  NavPhase? _lastNavPhase;
  DateTime? _lastPublish, _lastFetch, _lastFix, _retryPublishAt;
  String? _publishError, _fetchError;
  String? get error => _publishError ?? _fetchError;
  List<RiderPresence> riders = const [];
  bool get signedIn => _userId != null && backend.available;
  bool get active => sharing && signedIn && _nav?.phase == NavPhase.navigating;

  void bindNavigation(NavigationController nav) {
    if (identical(nav, _nav)) return;
    _nav?.removeListener(_schedule);
    _nav = nav;
    nav.addListener(_schedule);
    _schedule();
  }

  void setViewing(bool value) {
    viewing = value && signedIn;
    _generation++;
    riders = const [];
    truncated = false;
    _fetchError = null;
    _lastFetch = null;
    _notify();
    pulse();
  }

  void setSharing(bool value) {
    sharing = value && signedIn;
    _generation++;
    _publishError = null;
    _retryPublishAt = null;
    _schedule();
    _notify();
  }

  void setVisibility({required bool foreground, required bool mapVisible}) {
    _foreground = foreground;
    _mapVisible = mapVisible;
    if (!foreground || !mapVisible) {
      _generation++;
      riders = const [];
      _notify();
    }
    pulse();
  }

  Future<void> stopBeforeSignOut() async {
    sharing = viewing = false;
    _generation++;
    riders = const [];
    _notify();
    _schedule();
    // The worker serializes a pending begin/publish followed by withdrawal.
    // Never hang sign-out indefinitely on a cloud outage.
    final elapsed = Stopwatch()..start();
    while (_syncing &&
        !_disposed &&
        elapsed.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  void pulse() {
    if (_disposed) return;
    final live = riders.where((r) => r.expiresAt.isAfter(_now())).toList();
    if (live.length != riders.length) {
      riders = List.unmodifiable(live);
      _notify();
    }
    _schedule();
    if (viewing &&
        signedIn &&
        _foreground &&
        _mapVisible &&
        !_fetching &&
        (_lastFetch == null ||
            _now().difference(_lastFetch!) >= const Duration(seconds: 5))) {
      unawaited(_fetch());
    }
  }

  Future<void> _fetch() async {
    _fetching = true;
    _lastFetch = _now();
    final generation = _generation;
    try {
      final result = await backend.fetch();
      if (_disposed || generation != _generation || !viewing) return;
      riders = List.unmodifiable(
        result.riders.where((r) => r.expiresAt.isAfter(_now())),
      );
      truncated = result.truncated;
      _fetchError = null;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      riders = const [];
      _fetchError = 'unavailable';
    } finally {
      _fetching = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _schedule() {
    if (_disposed) return;
    final phase = _nav?.phase;
    if (phase != _lastNavPhase) {
      _lastNavPhase = phase;
      _tripGeneration++;
      _generation++;
    }
    _dirty = true;
    if (!_syncing) unawaited(_sync());
  }

  bool _usable(NavigationFix fix) =>
      RiderPresence.inSydney(fix) &&
      fix.accuracy.isFinite &&
      fix.accuracy >= 0 &&
      fix.accuracy <= 50 &&
      _now().difference(fix.timestamp).abs() <= const Duration(seconds: 10);
  Future<void> _sync() async {
    _syncing = true;
    try {
      while (_dirty && !_disposed) {
        _dirty = false;
        if (_session != null && _sessionTripGeneration != _tripGeneration) {
          final token = _session!;
          _session = null;
          _lastPublish = _lastFix = null;
          await backend.stop(token);
          _dirty = true;
          _notify();
          continue;
        }
        var fix = _nav?.voiceFix;
        final wanted = active && fix != null && _usable(fix);
        if (!wanted) {
          final token = _session;
          _session = null;
          _lastPublish = _lastFix = null;
          if (token != null) {
            await backend.stop(token);
            _notify();
          }
          continue;
        }
        final generation = _generation;
        final actor = _userId;
        if (_retryPublishAt != null && _now().isBefore(_retryPublishAt!)) continue;
        if (_session == null) {
          final token = await backend.begin();
          if (_disposed ||
              generation != _generation ||
              actor != _userId ||
              !active) {
            await backend.stop(token);
            continue;
          }
          _session = token;
          _sessionTripGeneration = _tripGeneration;
          _sequence = 0;
        }
        // Never publish the fix captured before awaited session creation.
        fix = _nav?.voiceFix;
        if (!active || fix == null || !_usable(fix)) {
          _dirty = true;
          continue;
        }
        if (_lastPublish != null &&
            _now().difference(_lastPublish!) < const Duration(seconds: 5)) {
          continue;
        }
        if (_lastFix == fix.timestamp) continue;
        _lastPublish = _now();
        final ok = await backend.publish(_session!, ++_sequence, fix);
        if (ok) {
          _lastFix = fix.timestamp;
          _publishError = null;
          _retryPublishAt = null;
        } else {
          final rejected = _session!;
          _session = null;
          _lastPublish = _lastFix = null;
          _publishError = 'unavailable';
          _retryPublishAt = _now().add(const Duration(seconds: 5));
          // A rejected update does not prove that the previous position was
          // removed. Keep its token long enough to explicitly withdraw it.
          await backend.stop(rejected);
        }
        _notify();
      }
    } catch (_) {
      _publishError = 'unavailable';
      _retryPublishAt = _now().add(const Duration(seconds: 5));
      _notify();
    } finally {
      _syncing = false;
      // Events that arrived during an await are not discarded after a failure.
      if (_dirty && !_disposed) {
        scheduleMicrotask(_schedule);
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _auth.cancel();
    _nav?.removeListener(_schedule);
    final token = _session;
    if (token != null) unawaited(backend.stop(token).catchError((Object _) {}));
    super.dispose();
  }
}
