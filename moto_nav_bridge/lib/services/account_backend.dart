import '../models/account_data.dart';

class AccountUser {
  const AccountUser(this.id, this.email, {this.apple = false});
  final String id, email;
  final bool apple;
}

abstract interface class AccountBackend {
  bool get available;
  bool get appleAvailable;
  bool get googleAvailable;
  AccountUser? get user;
  Stream<AccountUser?> get changes;
  Future<void> signIn(String email, String password);
  Future<void> register(String email, String password);
  Future<void> signInApple();
  Future<void> signInGoogle();
  Future<void> verifyEmail(String email, String code);
  Future<void> sendRecovery(String email);
  Future<void> resetPassword(String email, String code, String password);
  Future<void> signOut();
  Future<AccountData> download();
  Future<int> upload(AccountData data, int revision);
  Future<void> deleteAccount();
}

class AccountFailure implements Exception {
  const AccountFailure(this.code);
  final String code;
  @override
  String toString() => 'AccountFailure($code)'; // Never print auth exceptions or credentials.
}
