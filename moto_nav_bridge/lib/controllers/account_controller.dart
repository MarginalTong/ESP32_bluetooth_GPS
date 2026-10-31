import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/account_data.dart';
import '../services/account_backend.dart';
import '../services/local_account_data.dart';
import 'navigation_controller.dart';

/// Account/session ownership stays separate from background settings sync.
class AccountController extends ChangeNotifier {
  AccountController(this.backend, this.local);
  final AccountBackend backend;
  final LocalAccountData local;
  StreamSubscription<AccountUser?>? _authSubscription;
  NavigationController? _navigation;
  bool _lastCanModify = true, _settingsPending = false;
  AccountUser? _user;
  AccountUser? get user => _user;
  bool busy = false;
  bool _reconciling = false, _disposed = false;
  int localGeneration = 0;
  int settingsRevision = 0;
  String? error;
  DateTime? lastSync;
  bool get available => backend.available;
  bool get appleAvailable => backend.appleAvailable;
  bool get googleAvailable => backend.googleAvailable;
  bool get canModify => _navigation?.canEditPreferences ?? true;
  bool get identityReady =>
      !busy &&
      !_reconciling &&
      backend.user?.id == local.activeId &&
      _user?.id == local.activeId;
  bool get ready => identityReady && canModify;

  Future<void> initialize() async {
    await local.recover();
    await _reconcile();
    _authSubscription = backend.changes.listen(
      (_) {
        if (!busy) unawaited(_reconcile());
      },
      onError: (_) {
        error = 'session';
        _notify();
      },
    );
  }

  void bindNavigation(NavigationController navigation) {
    if (identical(_navigation, navigation)) return;
    _navigation?.removeListener(_navigationChanged);
    _navigation = navigation;
    _lastCanModify = canModify;
    navigation.addListener(_navigationChanged);
  }

  void _navigationChanged() {
    if (canModify && !busy) unawaited(_reconcile());
    if (canModify && _settingsPending) {
      _settingsPending = false;
      settingsDidSync();
    }
    if (_lastCanModify != canModify) {
      _lastCanModify = canModify;
      _notify();
    }
  }

  void settingsDidSync() {
    if (!canModify) {
      _settingsPending = true;
      return;
    }
    final p = local.capture().preferences;
    final nav = _navigation;
    if (nav != null &&
        (nav.avoidHighways != (p['avoid_highways'] == true) ||
            nav.avoidTolls != (p['avoid_tolls'] == true) ||
            nav.avoidFerries != (p['avoid_ferries'] == true) ||
            nav.avoidTunnels != (p['avoid_tunnels'] == true))) {
      nav.updatePreferences(
        highways: p['avoid_highways'] == true,
        tolls: p['avoid_tolls'] == true,
        ferries: p['avoid_ferries'] == true,
        tunnels: p['avoid_tunnels'] == true,
      );
    }
    settingsRevision++;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _applied() {
    final p = local.capture().preferences;
    _navigation?.updatePreferences(
      highways: p['avoid_highways'] == true,
      tolls: p['avoid_tolls'] == true,
      ferries: p['avoid_ferries'] == true,
      tunnels: p['avoid_tunnels'] == true,
    );
    localGeneration++;
  }

  Future<void> _reconcile() async {
    if (_disposed || busy || _reconciling || !canModify) return;
    final next = backend.user;
    if (next?.id == local.activeId && next?.id == _user?.id) {
      _user = next;
      return;
    }
    _reconciling = true;
    var switched = false;
    try {
      await local.activate(next?.id);
      _user = next;
      lastSync = null;
      _applied();
      switched = true;
    } catch (_) {
      error = 'local';
    } finally {
      _reconciling = false;
      _notify();
      if (switched &&
          !_disposed &&
          canModify &&
          backend.user?.id != local.activeId) {
        scheduleMicrotask(() => unawaited(_reconcile()));
      }
    }
  }

  Future<bool> _run(Future<void> Function() operation) async {
    if (_disposed) return false;
    if (busy || _reconciling || !canModify) {
      error = 'navigation_active';
      _notify();
      return false;
    }
    busy = true;
    error = null;
    _notify();
    var success = false;
    try {
      await operation();
      success = true;
    } on AccountFailure catch (e) {
      // Closing a provider's account picker is not a failed login.
      error = e.code == 'cancelled' ? null : e.code;
    } catch (_) {
      error = 'request';
    } finally {
      busy = false;
      await _reconcile();
      _notify();
    }
    return success;
  }

  Future<bool> signIn(String email, String password) =>
      _run(() => backend.signIn(email, password));
  Future<bool> register(String email, String password) =>
      _run(() => backend.register(email, password));
  Future<bool> signInApple() => _run(backend.signInApple);
  Future<bool> signInGoogle() => _run(backend.signInGoogle);
  Future<bool> verifyEmail(String email, String code) =>
      _run(() => backend.verifyEmail(email, code));
  Future<bool> sendRecovery(String email) =>
      _run(() => backend.sendRecovery(email));
  Future<bool> resetPassword(String email, String code, String password) =>
      _run(() => backend.resetPassword(email, code, password));
  Future<bool> signOut() => _run(backend.signOut);
  void _requireAccount() {
    if (_user == null ||
        backend.user?.id != _user?.id ||
        local.activeId != _user?.id) {
      throw const AccountFailure('session');
    }
  }

  Future<bool> download() => _run(() async {
    _requireAccount();
    final id = _user!.id;
    final before = jsonEncode(local.capture().toCache());
    final data = await backend.download();
    if (_disposed || backend.user?.id != id || !canModify) {
      throw const AccountFailure('session');
    }
    if (jsonEncode(local.capture().toCache()) != before) {
      throw const AccountFailure('local_changed');
    }
    await local.replace(data);
    _applied();
    lastSync = DateTime.now();
  });
  Future<bool> upload() => _run(() async {
    _requireAccount();
    final id = _user!.id;
    final data = local.capture();
    final revision = await backend.upload(data, data.revision);
    if (_disposed || backend.user?.id != id || !canModify) {
      throw const AccountFailure('session');
    }
    final latest = local.capture();
    await local.replace(
      AccountData(
        revision: revision,
        displayName: latest.displayName,
        places: latest.places,
        preferences: latest.preferences,
      ),
    );
    lastSync = DateTime.now();
  });
  Future<bool> importGuest() => _run(() async {
    _requireAccount();
    final guest = local.cached(null), current = local.capture();
    await local.replace(
      AccountData(
        revision: current.revision,
        displayName: current.displayName,
        places: guest.places,
        preferences: guest.preferences,
      ),
    );
    _applied();
  });
  Future<bool> deleteAccount() => _run(() async {
    _requireAccount();
    await backend.deleteAccount();
    await local.activate(null, erasePrevious: true);
    _user = null;
    lastSync = null;
    _applied();
  });
  @override
  void dispose() {
    _disposed = true;
    _authSubscription?.cancel();
    _navigation?.removeListener(_navigationChanged);
    super.dispose();
  }
}
