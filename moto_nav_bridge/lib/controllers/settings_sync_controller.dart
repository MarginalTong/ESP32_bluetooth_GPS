import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/account_data.dart';
import '../models/settings_merge.dart';
import '../services/settings_store.dart';
import 'account_controller.dart';

enum SettingsSyncStatus {
  guest,
  pending,
  syncing,
  synced,
  offline,
  conflict,
  deferred,
}

/// Event-driven, account-scoped sync. A durable last-synced snapshot acts as
/// the outbox: edits are rediscovered after restart even if a request failed.
class SettingsSyncController extends ChangeNotifier {
  SettingsSyncController(this.account) {
    account.addListener(_accountChanged);
    _edits = SettingsStore.edits.listen((event) {
      if (identical(event.store, account.local.preferences) &&
          event.actor == _actor) {
        request();
      }
    });
    _accountChanged();
  }
  final AccountController account;
  StreamSubscription<SettingsEdit>? _edits;
  Timer? _timer;
  String? _actor;
  int _generation = 0, _failures = 0;
  int get accountGeneration => _generation;
  bool _disposed = false, _running = false, _again = false, _wasReady = false;
  bool _foreground = true;
  SettingsSyncStatus status = SettingsSyncStatus.guest;
  List<String> conflicts = const [];
  AccountData? _reviewedLocal;
  int? _reviewedRevision;
  DateTime? lastSync;
  bool get _ready =>
      _foreground &&
      _actor != null &&
      account.ready &&
      account.user?.id == _actor;
  bool _current(String actor, int generation) =>
      !_disposed &&
      generation == _generation &&
      actor == _actor &&
      account.user?.id == actor &&
      account.backend.user?.id == actor &&
      account.local.activeId == actor;
  void _set(SettingsSyncStatus value) {
    status = value;
    if (!_disposed) notifyListeners();
  }

  void _accountChanged() {
    final next = account.user?.id;
    if (_actor != next) {
      _generation++;
      _timer?.cancel();
      _actor = next;
      _failures = 0;
      conflicts = const [];
      _reviewedLocal = null;
      _reviewedRevision = null;
      lastSync = null;
      _set(
        next == null ? SettingsSyncStatus.guest : SettingsSyncStatus.pending,
      );
      if (next != null) request();
    } else if (_ready && !_wasReady) {
      request();
    }
    _wasReady = _ready;
  }

  void request() {
    if (_disposed || _actor == null) return;
    _again = true;
    if (!_ready) {
      _set(SettingsSyncStatus.deferred);
      return;
    }
    if (!_running) _set(SettingsSyncStatus.pending);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 700), () => unawaited(flush()));
  }

  Future<void> resolve(SettingsChoice choice) => flush(choice: choice);
  void setForeground(bool value) {
    _foreground = value;
    if (value) {
      request();
    } else {
      _timer?.cancel();
    }
  }

  Future<void> flush({SettingsChoice? choice}) async {
    _timer?.cancel();
    if (_disposed || _actor == null || _running) return;
    if (!_ready) {
      _set(SettingsSyncStatus.deferred);
      return;
    }
    final actor = _actor!, generation = _generation;
    final reviewedRevision = _reviewedRevision, reviewedLocal = _reviewedLocal;
    _running = true;
    _again = false;
    _set(SettingsSyncStatus.syncing);
    try {
      final cloud = await account.backend.download().timeout(
        const Duration(seconds: 10),
      );
      if (!_current(actor, generation)) return;
      final before = await account.local.snapshot();
      if (!_current(actor, generation)) return;
      final base = account.local.syncBase(actor);
      final acceptedChoice =
          choice != null &&
              reviewedRevision == cloud.revision &&
              reviewedLocal != null &&
              sameSettings(reviewedLocal, before)
          ? choice
          : null;
      final merged = mergeSettings(base, before, cloud, choice: acceptedChoice);
      if (merged.conflicts.isNotEmpty && acceptedChoice == null) {
        conflicts = merged.conflicts;
        _reviewedLocal = before;
        _reviewedRevision = cloud.revision;
        _set(SettingsSyncStatus.conflict);
        return;
      }
      if (!_ready) {
        _set(SettingsSyncStatus.deferred);
        return;
      }
      final uploaded = !sameSettings(merged.data, cloud);
      var saved = cloud;
      if (uploaded) {
        final revision = await account.backend
            .upload(merged.data, cloud.revision, expectedUser: actor)
            .timeout(const Duration(seconds: 10));
        saved = AccountData(
          revision: revision,
          displayName: cloud.displayName,
          places: merged.data.places,
          preferences: merged.data.preferences,
        );
      }
      if (!_current(actor, generation)) return;
      final changed = await account.local.acceptSync(
        actor,
        before,
        saved,
        uploaded: uploaded,
        canApply: () => _current(actor, generation) && _ready,
      );
      if (!_current(actor, generation)) return;
      if (changed == null) {
        _again = true;
        _set(_ready ? SettingsSyncStatus.pending : SettingsSyncStatus.deferred);
        return;
      }
      if (changed) account.settingsDidSync();
      conflicts = const [];
      _reviewedLocal = null;
      _reviewedRevision = null;
      _failures = 0;
      lastSync = DateTime.now();
      _again = !sameSettings(await account.local.snapshot(), saved);
      if (!_current(actor, generation)) return;
      _set(_again ? SettingsSyncStatus.pending : SettingsSyncStatus.synced);
    } catch (_) {
      if (_current(actor, generation)) {
        _again = true;
        _failures++;
        _set(SettingsSyncStatus.offline);
      }
    } finally {
      _running = false;
      if (!_disposed &&
          _actor != null &&
          _again &&
          _ready &&
          status != SettingsSyncStatus.conflict) {
        _timer?.cancel();
        final delay = _failures == 0
            ? const Duration(milliseconds: 700)
            : Duration(
                seconds: [2, 5, 15, 30, 60][(_failures - 1).clamp(0, 4)],
              );
        _timer = Timer(delay, () => unawaited(flush()));
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _edits?.cancel();
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
