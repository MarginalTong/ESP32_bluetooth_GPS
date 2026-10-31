import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsEdit {
  const SettingsEdit(this.store, this.actor);
  final SharedPreferences store;
  final String? actor;
}

/// Serialize short disk mutations, never network requests. Account switches and
/// edits use the same queue so an old page cannot write into a new account.
abstract final class SettingsStore {
  static const _unspecified = Object();
  static const activeKey = 'navio.account.active';
  static final _queues = Expando<_Queue>();
  static final _edits = StreamController<SettingsEdit>.broadcast(sync: true);
  static Stream<SettingsEdit> get edits => _edits.stream;
  static Future<T> serial<T>(
    SharedPreferences store,
    Future<T> Function() action,
  ) {
    final queue = _queues[store] ??= _Queue();
    final previous = queue.tail;
    final finished = Completer<void>();
    queue.tail = finished.future;
    Future<T> run() async {
      if (previous != null) await previous;
      try {
        return await action();
      } finally {
        if (identical(queue.tail, finished.future)) queue.tail = null;
        finished.complete();
      }
    }

    return run();
  }

  static Future<T> edit<T>(
    SharedPreferences store,
    Future<T> Function() action, {
    Object? expectedActor = _unspecified,
  }) {
    final actor = identical(expectedActor, _unspecified)
        ? store.getString(activeKey)
        : expectedActor as String?;
    return serial(store, () async {
      if (store.getString(activeKey) != actor) {
        throw StateError('Account changed');
      }
      final result = await action();
      _edits.add(SettingsEdit(store, actor));
      return result;
    });
  }
}

class _Queue {
  Future<void>? tail;
}
