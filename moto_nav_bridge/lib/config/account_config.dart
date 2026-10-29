import 'dart:convert';

class AccountConfig {
  const AccountConfig(
      {required this.url,
      required this.publishableKey,
      this.appleEnabled = false});
  static const environment = AccountConfig(
    url: String.fromEnvironment('SUPABASE_URL'),
    publishableKey: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    appleEnabled: bool.fromEnvironment('NAVIO_APPLE_SIGN_IN'),
  );
  final String url, publishableKey;
  final bool appleEnabled;

  bool get configured {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return false;
    }
    if (publishableKey.startsWith('sb_publishable_')) {
      return publishableKey.length > 25;
    }
    // Accept the old public anon JWT, never a secret/service_role key.
    try {
      final parts = publishableKey.split('.');
      return parts.length == 3 &&
          (jsonDecode(utf8
                      .decode(base64Url.decode(base64Url.normalize(parts[1]))))
                  as Map)['role'] ==
              'anon';
    } catch (_) {
      return false;
    }
  }
}
