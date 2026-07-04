/// Configuration for external map services.
///
/// The Google Directions API key is read from a compile-time environment
/// variable so it never has to be committed to source control:
///
///   flutter run --dart-define=GOOGLE_DIRECTIONS_API_KEY=your_key_here
///   flutter build apk --dart-define=GOOGLE_DIRECTIONS_API_KEY=your_key_here
///
/// If you prefer, you can hardcode a key into [_fallbackKey] for local
/// testing — but do NOT commit a real key.
class ApiConfig {
  const ApiConfig._();

  /// TODO: for quick local testing only. Leave empty and use --dart-define
  /// for anything you'll commit or ship.
  static const String _fallbackKey = '';

  static const String googleDirectionsApiKey = String.fromEnvironment(
    'GOOGLE_DIRECTIONS_API_KEY',
    defaultValue: _fallbackKey,
  );

  static bool get hasDirectionsKey => googleDirectionsApiKey.isNotEmpty;
}
