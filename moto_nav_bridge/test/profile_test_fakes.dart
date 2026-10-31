import 'dart:async';
import 'package:moto_nav_bridge/models/account_profile.dart';
import 'package:moto_nav_bridge/services/profile_backend.dart';

class FakeProfileBackend implements ProfileBackend {
  final profiles = <String, AccountProfile>{
    'user-a': const AccountProfile('NAVIO_7C2A9F10', 0),
    'user-b': const AccountProfile('Second rider', 0),
  };
  final fetchGates = <String, Completer<AccountProfile>>{};
  Completer<AccountProfile>? renameGate;
  int fetches = 0, writes = 0;
  bool failFetch = false, failWrite = false;
  String? lastActor;
  @override
  Future<AccountProfile> fetch(String expectedUser) async {
    fetches++;
    if (failFetch) throw const ProfileFailure('unavailable');
    return fetchGates[expectedUser]?.future ?? profiles[expectedUser]!;
  }

  @override
  Future<AccountProfile> rename(
    String expectedUser,
    String name,
    int expectedRevision,
  ) async {
    writes++;
    lastActor = expectedUser;
    if (failWrite) throw const ProfileFailure('unavailable');
    if (renameGate != null) return renameGate!.future;
    final old = profiles[expectedUser]!;
    if (name == old.displayName && expectedRevision <= old.revision) return old;
    if (expectedRevision != old.revision)
      throw const ProfileFailure('conflict');
    return profiles[expectedUser] = AccountProfile(name, old.revision + 1);
  }
}
