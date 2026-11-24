import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'offline_trip.dart';

abstract interface class NavigationSessionStore {
  Future<void> save(OfflineTrip trip);
  Future<void> checkpoint(TripProgress progress);
  Future<OfflineTrip?> load();
  Future<void> clear();
  Future<void> flush();
}

/// Two atomic files: immutable geometry per route revision + a small checkpoint.
/// Writes are ordered, so a delayed write cannot resurrect an explicitly ended trip.
class FileNavigationSessionStore implements NavigationSessionStore {
  FileNavigationSessionStore({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;
  final Future<Directory> Function() _directory;
  Future<void> _pending = Future.value();
  static const maxDocumentBytes = 32 * 1024 * 1024;

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/navigation_session',
  );

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _pending.then((_) => task());
    _pending = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> save(OfflineTrip trip) => _enqueue(() async {
    // Geometry encoding and hashing do not run in the GPS/UI isolate.
    final encoded = await _encodeTrip(trip);
    await _write('route.json', encoded);
  });

  @override
  Future<void> checkpoint(TripProgress progress) => _enqueue(() async {
    await _write('progress.json', _encode(progress.toMap()));
  });

  static String _encode(Map<String, Object?> value) {
    final body = jsonEncode(value);
    return jsonEncode({
      'body': body,
      'sha256': sha256.convert(utf8.encode(body)).toString(),
    });
  }

  Future<void> _write(String name, String encoded) async {
    final bytes = utf8.encode(encoded);
    if (bytes.length > maxDocumentBytes) {
      throw const FormatException('Trip too large');
    }
    final dir = await _directory();
    await dir.create(recursive: true);
    final temp = File('${dir.path}/$name.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    // Same-directory rename keeps the previous complete file until replacement.
    await temp.rename('${dir.path}/$name');
  }

  Future<Map<String, dynamic>?> _read(String name) async {
    final dir = await _directory();
    final file = File('${dir.path}/$name');
    if (!await file.exists()) return null;
    if (await file.length() > maxDocumentBytes) {
      throw const FormatException('Trip too large');
    }
    final envelope = jsonDecode(await file.readAsString()) as Map;
    final body = envelope['body'] as String;
    if (sha256.convert(utf8.encode(body)).toString() != envelope['sha256']) {
      throw const FormatException('Trip checksum mismatch');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  @override
  Future<OfflineTrip?> load() async {
    await _pending;
    final map = await _read('route.json');
    if (map == null) return null;
    final trip = OfflineTrip.fromMap(map);
    // A corrupt checkpoint must not destroy a usable full route. It falls back
    // to the route's initial progress, which still requires rider confirmation.
    try {
      final value = await _read('progress.json');
      if (value != null) {
        final progress = TripProgress.fromMap(value);
        if (progress.id == trip.id) return trip.withProgress(progress);
      }
    } catch (_) {
      /* The complete route document remains usable. */
    }
    return trip;
  }

  @override
  Future<void> clear() => _enqueue(() async {
    final dir = await _directory();
    // Delete geometry first: interruption cannot revive a completed trip.
    for (final name in ['route.json', 'progress.json']) {
      final file = File('${dir.path}/$name');
      if (await file.exists()) await file.delete();
    }
  });

  @override
  Future<void> flush() => _pending;
}

// A separate closure scope avoids capturing the store and its unsendable
// pending Future when creating the worker isolate.
Future<String> _encodeTrip(OfflineTrip trip) =>
    Isolate.run(() => FileNavigationSessionStore._encode(trip.toMap()));
