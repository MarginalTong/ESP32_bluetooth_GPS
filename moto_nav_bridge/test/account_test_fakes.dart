import 'dart:async';
import 'package:moto_nav_bridge/models/account_data.dart';
import 'package:moto_nav_bridge/services/account_backend.dart';

class FakeAccountBackend implements AccountBackend {
  @override
  bool available = true;
  @override
  bool appleAvailable = true;
  @override
  bool googleAvailable = false;
  int googleCalls = 0;
  bool cancelGoogle = false;
  @override
  AccountUser? user;
  final events = StreamController<AccountUser?>.broadcast(sync: true);
  @override
  Stream<AccountUser?> get changes => events.stream;
  String nextId = 'user-a';
  bool fail = false;
  int uploads = 0, deletions = 0, appleCalls = 0, recoveries = 0;
  AccountData cloud = const AccountData();
  Completer<AccountData>? pendingDownload;
  Completer<void>? uploadGate;
  void emit(AccountUser? value) {
    user = value;
    events.add(value);
  }

  void check() {
    if (fail) throw const AccountFailure('request');
  }

  @override
  Future<void> signIn(String email, String password) async {
    check();
    emit(AccountUser(nextId, email));
  }

  @override
  Future<void> register(String email, String password) async {
    check();
  }

  @override
  Future<void> signInApple() async {
    check();
    appleCalls++;
    emit(AccountUser(nextId, 'relay@example.test', apple: true));
  }

  @override
  Future<void> signInGoogle() async {
    if (cancelGoogle) throw const AccountFailure('cancelled');
    check();
    googleCalls++;
    emit(AccountUser(nextId, 'google@example.test'));
  }

  @override
  Future<void> verifyEmail(String email, String code) => signIn(email, code);
  @override
  Future<void> sendRecovery(String email) async {
    check();
    recoveries++;
  }

  @override
  Future<void> resetPassword(String email, String code, String password) =>
      signIn(email, password);
  @override
  Future<void> signOut() async {
    check();
    emit(null);
  }

  @override
  Future<AccountData> download() async {
    check();
    if (pendingDownload != null) return await pendingDownload!.future;
    return cloud;
  }

  @override
  Future<int> upload(
    AccountData data,
    int revision, {
    String? expectedUser,
  }) async {
    await uploadGate?.future;
    check();
    if (expectedUser != null && user?.id != expectedUser) {
      throw const AccountFailure('session');
    }
    if (revision != cloud.revision) throw const AccountFailure('conflict');
    uploads++;
    cloud = AccountData(
      revision: revision + 1,
      displayName: data.displayName,
      places: data.places,
      preferences: data.preferences,
    );
    return cloud.revision;
  }

  @override
  Future<void> deleteAccount() async {
    check();
    deletions++;
    emit(null);
  }
}
