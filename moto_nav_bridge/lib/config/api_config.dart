/// Configuration for the Valhalla routing server.
class ApiConfig {
  const ApiConfig._();

  /// Single production origin. Legacy VALHALLA_ROUTE_URL build defines are
  /// intentionally ignored so stale Xcode settings cannot select the old server.
  static const String valhallaBaseUrl = 'https://nav.williamligallery.uk';
  static const String valhallaRouteUrl = '$valhallaBaseUrl/route';
  static const String valhallaStatusUrl = '$valhallaBaseUrl/status';
}
