import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/account_config.dart';
import '../models/account_data.dart';
import 'account_backend.dart';
import 'secure_auth_storage.dart';
import 'google_account_sign_in.dart';

class SupabaseAccountBackend implements AccountBackend {
  SupabaseAccountBackend(this.client, {this.appleEnabled = false, this.google});
  final SupabaseClient? client;
  final bool appleEnabled;
  final GoogleAccountSignIn? google;
  Future<void> Function()? beforeSignOut;
  static Future<SupabaseAccountBackend> initialize(AccountConfig config) async {
    if (!config.configured) return SupabaseAccountBackend(null);
    final secure = SecureAuthStorage(Uri.parse(config.url).host);
    final supabase = await Supabase.initialize(
      url: config.url,
      publishableKey: config.publishableKey,
      authOptions: FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: secure,
        pkceAsyncStorage: SecurePkceStorage(secure),
      ),
      debug: false,
    );
    return SupabaseAccountBackend(
      supabase.client,
      appleEnabled: config.appleEnabled,
      google: NativeGoogleAccountSignIn(config),
    );
  }

  SupabaseClient get _client =>
      client ?? (throw const AccountFailure('unconfigured'));
  @override
  bool get available => client != null;
  @override
  bool get googleAvailable => available && (google?.available ?? false);
  @override
  bool get appleAvailable =>
      available &&
      appleEnabled &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);
  AccountUser? _user(User? value) => value == null
      ? null
      : AccountUser(
          value.id,
          value.email ?? '',
          apple: value.identities?.any((i) => i.provider == 'apple') ?? false,
        );
  @override
  AccountUser? get user => _user(client?.auth.currentUser);
  @override
  Stream<AccountUser?> get changes =>
      client?.auth.onAuthStateChange.map((e) => _user(e.session?.user)) ??
      const Stream.empty();
  @override
  Future<void> signIn(String email, String password) async {
    await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  }

  @override
  Future<void> register(String email, String password) async {
    await _client.auth.signUp(email: email.trim(), password: password);
  }

  @override
  Future<void> verifyEmail(String email, String code) async {
    await _client.auth.verifyOTP(
      email: email.trim(),
      token: code.trim(),
      type: OtpType.email,
    );
  }

  @override
  Future<void> sendRecovery(String email) =>
      _client.auth.resetPasswordForEmail(email.trim());
  @override
  Future<void> resetPassword(String email, String code, String password) async {
    await _client.auth.verifyOTP(
      email: email.trim(),
      token: code.trim(),
      type: OtpType.recovery,
    );
    await _client.auth.updateUser(UserAttributes(password: password));
  }

  @override
  Future<void> signInApple() async {
    if (!appleAvailable) throw const AccountFailure('apple_unconfigured');
    final nonce = _client.auth.generateRawNonce();
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: sha256.convert(utf8.encode(nonce)).toString(),
    );
    if (credential.identityToken == null) {
      throw const AccountFailure('apple_failed');
    }
    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: credential.identityToken!,
      nonce: nonce,
    );
    // Save the revocable provider grant server-side before treating onboarding
    // as complete. No Apple private key or refresh token is kept in the app.
    try {
      final result = await _client.functions.invoke(
        'account-actions',
        body: {
          'action': 'register_apple',
          'code': credential.authorizationCode,
        },
      );
      if (result.status != 200) {
        throw const AccountFailure('apple_grant_failed');
      }
    } catch (_) {
      await signOut();
      throw const AccountFailure('apple_grant_failed');
    }
  }

  @override
  Future<void> signOut() async {
    await beforeSignOut?.call();
    // The SDK clears the local session before its network revocation request.
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      if (_client.auth.currentSession != null) rethrow;
    }
  }

  @override
  Future<void> signInGoogle() async {
    if (!googleAvailable) throw const AccountFailure('google_unconfigured');
    final credential = await google!.authenticate();
    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: credential.idToken,
      nonce: credential.nonce,
    );
  }

  @override
  Future<AccountData> download() async => AccountData.fromCloud(
    Map<String, dynamic>.from(await _client.rpc('navio_get_account_data')),
  );
  @override
  Future<int> upload(AccountData data, int revision) async {
    try {
      final result = await _client.rpc(
        'navio_save_account_data',
        params: {'payload': data.toCloud(), 'expected_revision': revision},
      );
      return (result as num).toInt();
    } on PostgrestException catch (e) {
      if (e.code == 'PT409') throw const AccountFailure('conflict');
      rethrow;
    }
  }

  @override
  Future<void> deleteAccount() async {
    if (user?.apple == true) {
      final result = await _client.functions.invoke(
        'account-actions',
        body: {'action': 'delete_account', 'confirmation': 'DELETE'},
      );
      if (result.status != 200) throw const AccountFailure('delete_failed');
    } else {
      await _client.rpc(
        'navio_delete_email_account',
        params: {'confirmation': 'DELETE'},
      );
    }
    await signOut();
  }
}
