import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../config/account_config.dart';
import 'account_backend.dart';

/// Credentials exist only for the ID-token exchange; never persist or log them.
class GoogleAccountCredential {
  const GoogleAccountCredential(this.idToken, this.nonce);
  final String idToken, nonce;
  @override
  String toString() => 'GoogleAccountCredential(<redacted>)';
}

abstract interface class GoogleAccountSignIn {
  bool get available;
  Future<GoogleAccountCredential> authenticate();
}

/// Small adapter so SDK initialization/cancellation can be tested without UI.
abstract interface class GoogleIdentityClient {
  Future<void> initialize({
    String? clientId,
    required String serverClientId,
    required String nonce,
  });
  Future<void> signOut();
  Future<String?> authenticate();
}

class _GoogleIdentityClient implements GoogleIdentityClient {
  final sdk = GoogleSignIn.instance;
  @override
  Future<void> initialize({
    String? clientId,
    required String serverClientId,
    required String nonce,
  }) => sdk.initialize(
    clientId: clientId,
    serverClientId: serverClientId,
    nonce: nonce,
  );
  @override
  Future<void> signOut() => sdk.signOut();
  @override
  Future<String?> authenticate() async =>
      (await sdk.authenticate()).authentication.idToken;
}

class NativeGoogleAccountSignIn implements GoogleAccountSignIn {
  NativeGoogleAccountSignIn(
    this.config, {
    GoogleIdentityClient? client,
    TargetPlatform? platform,
    Future<bool> Function(String)? hasIosScheme,
    String Function()? generateNonce,
  }) : _client = client ?? _GoogleIdentityClient(),
       _platform = platform ?? defaultTargetPlatform,
       _hasIosScheme = hasIosScheme ?? _nativeHasIosScheme,
       _generateNonce = generateNonce ?? _randomNonce;
  final AccountConfig config;
  final GoogleIdentityClient _client;
  final TargetPlatform _platform;
  final Future<bool> Function(String) _hasIosScheme;
  final String Function() _generateNonce;
  Future<void>? _initializing;
  String? _nonce;
  static const _channel = MethodChannel('moto_nav_bridge/auth_configuration');
  static String _randomNonce() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));
  }

  static Future<bool> _nativeHasIosScheme(String scheme) async =>
      await _channel.invokeMethod<bool>('hasUrlScheme', scheme) ?? false;

  @override
  bool get available =>
      !kIsWeb &&
      config.configured &&
      config.googleEnabled &&
      AccountConfig.isGoogleClientId(config.googleWebClientId) &&
      (_platform == TargetPlatform.android ||
          (_platform == TargetPlatform.iOS &&
              AccountConfig.isGoogleClientId(config.googleIosClientId)));

  Future<void> _initialize() async {
    // A missing iOS callback scheme can throw an Objective-C exception. Check
    // the built bundle before entering Google's native SDK, not just Dart IDs.
    if (_platform == TargetPlatform.iOS &&
        !await _hasIosScheme(config.googleIosUrlScheme)) {
      throw const AccountFailure('google_unconfigured');
    }
    // google_sign_in must initialize exactly once per process. The random raw
    // nonce stays in memory for that SDK lifetime; only its hash reaches Google.
    // Do not reinitialize the SDK to rotate it or disable Supabase nonce checks.
    _nonce = _generateNonce();
    await _client.initialize(
      clientId: _platform == TargetPlatform.iOS
          ? config.googleIosClientId
          : null,
      serverClientId: config.googleWebClientId,
      nonce: sha256.convert(utf8.encode(_nonce!)).toString(),
    );
  }

  @override
  Future<GoogleAccountCredential> authenticate() async {
    if (!available) throw const AccountFailure('google_unconfigured');
    try {
      await (_initializing ??= _initialize());
      // Forget the SDK selection so signing out of NAVIO cannot silently sign
      // the next rider into the previous Google account. This does not revoke
      // Google permission or sign the phone out of Google services.
      await _client.signOut();
      final token = await _client.authenticate();
      if (token == null || token.isEmpty) {
        throw const AccountFailure('google_failed');
      }
      return GoogleAccountCredential(token, _nonce!);
    } on GoogleSignInException catch (e) {
      throw AccountFailure(switch (e.code) {
        GoogleSignInExceptionCode.canceled => 'cancelled',
        GoogleSignInExceptionCode.clientConfigurationError ||
        GoogleSignInExceptionCode.providerConfigurationError =>
          'google_unconfigured',
        _ => 'google_failed',
      });
    }
  }
}
