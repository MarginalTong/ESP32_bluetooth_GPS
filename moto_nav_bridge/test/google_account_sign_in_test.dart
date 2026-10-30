import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:moto_nav_bridge/config/account_config.dart';
import 'package:moto_nav_bridge/services/account_backend.dart';
import 'package:moto_nav_bridge/services/google_account_sign_in.dart';
import 'package:moto_nav_bridge/services/supabase_account_backend.dart';

const config = AccountConfig(
  url: 'https://navio-test.invalid',
  publishableKey: 'sb_publishable_12345678901234567890',
  googleEnabled: true,
  googleWebClientId: '123-web.apps.googleusercontent.com',
  googleIosClientId: '123-ios.apps.googleusercontent.com',
);

class FakeGoogleClient implements GoogleIdentityClient {
  int initializes = 0, selections = 0, signOuts = 0;
  String? clientId, serverClientId, nonce;
  String? token = 'synthetic-id-token';
  GoogleSignInExceptionCode? failure;
  @override
  Future<void> initialize({
    String? clientId,
    required String serverClientId,
    required String nonce,
  }) async {
    initializes++;
    this.clientId = clientId;
    this.serverClientId = serverClientId;
    this.nonce = nonce;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
  }

  @override
  Future<String?> authenticate() async {
    selections++;
    if (failure != null) {
      throw GoogleSignInException(
        code: failure!,
        description: 'sensitive native error',
      );
    }
    return token;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeGoogleClient sdk;
  NativeGoogleAccountSignIn service({
    TargetPlatform platform = TargetPlatform.iOS,
    AccountConfig settings = config,
    bool scheme = true,
  }) => NativeGoogleAccountSignIn(
    settings,
    client: sdk,
    platform: platform,
    hasIosScheme: (actual) async =>
        scheme && actual == config.googleIosUrlScheme,
    generateNonce: () => 'synthetic-raw-nonce',
  );
  setUp(() => sdk = FakeGoogleClient());
  test(
    'iOS sends only the nonce hash to Google and initializes once',
    () async {
      final provider = service();
      final first = await provider.authenticate();
      await provider.authenticate();
      expect(sdk.initializes, 1);
      expect(sdk.selections, 2);
      expect(sdk.signOuts, 2);
      expect(sdk.clientId, config.googleIosClientId);
      expect(sdk.serverClientId, config.googleWebClientId);
      expect(sdk.nonce, sha256.convert(utf8.encode(first.nonce)).toString());
      expect(sdk.nonce, isNot(first.nonce));
      expect(first.toString(), isNot(contains(first.idToken)));
      expect(first.toString(), isNot(contains(first.nonce)));
    },
  );
  test('Android requests a server audience without an iOS client ID', () async {
    final provider = service(platform: TargetPlatform.android);
    expect(provider.available, isTrue);
    await provider.authenticate();
    expect(sdk.clientId, isNull);
    expect(sdk.serverClientId, config.googleWebClientId);
  });
  test('missing callback scheme fails before invoking native SDK', () async {
    await expectLater(
      service(scheme: false).authenticate(),
      throwsA(
        isA<AccountFailure>().having(
          (e) => e.code,
          'code',
          'google_unconfigured',
        ),
      ),
    );
    expect(sdk.initializes, 0);
    expect(sdk.selections, 0);
  });
  test('missing or disabled Google configuration hides the provider', () {
    expect(
      service(
        settings: const AccountConfig(
          url: 'https://example.invalid',
          publishableKey: '',
        ),
      ).available,
      isFalse,
    );
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.fuchsia,
    ]) {
      expect(service(platform: platform).available, isFalse);
    }
    for (final id in [
      '',
      'secret',
      'abc.apps.googleusercontent.com',
      '123-ios.apps.googleusercontent.com.attacker.invalid',
      '123-ios.apps.googleusercontent.com\n',
    ]) {
      expect(AccountConfig.isGoogleClientId(id), isFalse);
    }
  });
  test('empty ID tokens cannot reach the Supabase exchange', () async {
    sdk.token = '';
    await expectLater(
      service().authenticate(),
      throwsA(
        isA<AccountFailure>().having((e) => e.code, 'code', 'google_failed'),
      ),
    );
  });
  for (final failure in GoogleSignInExceptionCode.values) {
    test('SDK $failure maps to a safe application error', () async {
      sdk.failure = failure;
      final expected = switch (failure) {
        GoogleSignInExceptionCode.canceled => 'cancelled',
        GoogleSignInExceptionCode.clientConfigurationError ||
        GoogleSignInExceptionCode.providerConfigurationError =>
          'google_unconfigured',
        _ => 'google_failed',
      };
      await expectLater(
        service().authenticate(),
        throwsA(
          isA<AccountFailure>()
              .having((e) => e.code, 'code', expected)
              .having(
                (e) => e.toString(),
                'safe message',
                isNot(contains('sensitive')),
              ),
        ),
      );
    });
  }
  test(
    'real Supabase SDK exchanges the Google ID token with the raw nonce',
    () async {
      Map<String, dynamic>? body;
      final client = SupabaseClient(
        'https://navio-test.invalid',
        'public-test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/auth/v1/token');
          expect(request.url.queryParameters['grant_type'], 'id_token');
          body = jsonDecode(request.body) as Map<String, dynamic>;
          // A rejected exchange must not activate a local account. No network.
          return http.Response(
            '{"error":"invalid_grant","msg":"test rejection"}',
            400,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final backend = SupabaseAccountBackend(client, google: service());
      expect(backend.googleAvailable, isTrue);
      await expectLater(backend.signInGoogle(), throwsA(isA<AuthException>()));
      expect(body!['provider'], 'google');
      expect(body!['id_token'], 'synthetic-id-token');
      expect(body!['nonce'], 'synthetic-raw-nonce');
      expect(body!['access_token'], isNull);
      expect(backend.user, isNull);
      await client.dispose();
    },
  );
}
