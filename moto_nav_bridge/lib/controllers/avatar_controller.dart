import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/profile_avatar.dart';
import '../services/avatar_backend.dart';
import '../services/avatar_photo_source.dart';
import 'account_controller.dart';

class AvatarController extends ChangeNotifier {
  AvatarController(this.account, this.backend, {AvatarPhotoSource? source})
    : source = source ?? GalleryAvatarPhotoSource() {
    account.addListener(_accountChanged);
    _accountChanged();
  }
  final AccountController account;
  final AvatarBackend backend;
  final AvatarPhotoSource source;
  ProfileAvatar? avatar;
  bool busy = false;
  String? error;
  String? _userId;
  int _generation = 0;
  bool _disposed = false;
  bool get canEdit => _userId != null && account.ready && !busy;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation, String actor) =>
      !_disposed && generation == _generation && account.user?.id == actor;

  void _accountChanged() {
    final id = account.user?.id;
    if (id == _userId) {
      _notify();
      return;
    }
    _userId = id;
    _generation++;
    avatar = null;
    error = null;
    busy = false;
    _notify();
    if (id != null) unawaited(refresh());
  }

  Future<void> refresh() async {
    final actor = _userId;
    if (actor == null || busy || _disposed) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await backend.fetchOwn();
      if (_current(generation, actor)) avatar = result;
    } catch (_) {
      if (_current(generation, actor)) error = 'unavailable';
    } finally {
      if (_current(generation, actor)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> choose({Future<bool> Function(Uint8List)? confirm}) async {
    if (!canEdit) return;
    final actor = _userId!;
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      final jpeg = await source.choose();
      if (jpeg == null || !_current(generation, actor)) return;
      if (confirm != null && !await confirm(jpeg)) return;
      if (!_current(generation, actor)) return;
      if (!account.canModify) throw StateError('Navigation active');
      final saved = await backend.upload(actor, jpeg);
      if (_current(generation, actor)) avatar = saved;
    } catch (_) {
      if (_current(generation, actor)) error = 'save_failed';
    } finally {
      if (_current(generation, actor)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> remove() async {
    if (!canEdit || avatar == null) return;
    final actor = _userId!;
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      await backend.remove(actor);
      if (_current(generation, actor)) avatar = null;
    } catch (_) {
      if (_current(generation, actor)) error = 'save_failed';
    } finally {
      if (_current(generation, actor)) {
        busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    account.removeListener(_accountChanged);
    super.dispose();
  }
}
