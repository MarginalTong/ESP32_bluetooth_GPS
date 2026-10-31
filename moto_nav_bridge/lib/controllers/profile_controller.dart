import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/account_profile.dart';
import '../services/profile_backend.dart';
import 'account_controller.dart';

/// Own-profile traffic never applies settings or rebuilds a running map.
class ProfileController extends ChangeNotifier {
  ProfileController(this.account, this.backend, this.preferences) {
    account.addListener(_accountChanged);
    _accountChanged();
  }
  final AccountController account;
  final ProfileBackend backend;
  final SharedPreferences preferences;
  AccountProfile? profile;
  String? error;
  bool busy = false;
  bool _disposed = false;
  String? _actor;
  int _generation = 0;
  int _accountGeneration = 0;
  int get accountGeneration => _accountGeneration;
  bool get canEdit =>
      _actor != null && profile != null && account.identityReady && !busy;
  String _key(String id) => 'navio.profile.name.$id';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(String actor, int generation) =>
      !_disposed &&
      generation == _generation &&
      _actor == actor &&
      account.user?.id == actor &&
      account.backend.user?.id == actor &&
      account.local.activeId == actor;

  void _accountChanged() {
    final next = account.user?.id;
    if (_actor == next) {
      _notify();
      return;
    }
    final previous = _actor;
    _actor = next;
    _accountGeneration++;
    _generation++;
    busy = false;
    error = null;
    profile = null;
    if (previous != null) unawaited(_forgetCache(previous));
    if (next != null) {
      try {
        final cached = preferences.getString(_key(next));
        if (cached != null) {
          profile = AccountProfile.fromJson(
            jsonDecode(cached) as Map<String, dynamic>,
          );
        }
      } catch (_) {
        /* A bad cache must not block login. */
      }
    }
    _notify();
    if (next != null) unawaited(refresh());
  }

  Future<void> _forgetCache(String id) async {
    try {
      await preferences.remove(_key(id));
    } catch (_) {
      /* Never block sign-out. */
    }
  }

  Future<void> _cache(
    String actor,
    int generation,
    AccountProfile value,
  ) async {
    if (!_current(actor, generation)) return;
    // Cloud is authoritative; a cache write failure does not undo a saved name.
    try {
      await preferences.setString(_key(actor), jsonEncode(value.toJson()));
    } catch (_) {
      /* Optional offline cache. */
    }
  }

  Future<void> refresh() async {
    final actor = _actor;
    if (_disposed || busy || actor == null || !account.identityReady) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await backend.fetch(actor);
      if (!_current(actor, generation)) return;
      profile = result;
      await _cache(actor, generation, result);
    } catch (_) {
      if (_current(actor, generation)) error = 'unavailable';
    } finally {
      if (_current(actor, generation)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<bool> rename(String value, {required int expectedRevision}) async {
    if (!canEdit) return false;
    final name = value.trim();
    if (!AccountProfile.validName(name)) {
      error = 'invalid';
      _notify();
      return false;
    }
    final actor = _actor!, generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      final saved = await backend.rename(actor, name, expectedRevision);
      if (!_current(actor, generation)) return false;
      profile = saved;
      await _cache(actor, generation, saved);
      return _current(actor, generation);
    } on ProfileFailure catch (e) {
      if (_current(actor, generation)) {
        error = e.code;
        if (e.code == 'conflict') {
          try {
            final latest = await backend.fetch(actor);
            if (_current(actor, generation)) {
              profile = latest;
              await _cache(actor, generation, latest);
            }
          } catch (_) {
            /* Keep the draft and conflict; never overwrite it. */
          }
        }
      }
    } catch (_) {
      if (_current(actor, generation)) error = 'unavailable';
    } finally {
      if (_current(actor, generation)) {
        busy = false;
        _notify();
      }
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
