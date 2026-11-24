/// Thrown when route planning fails or returns no usable route.
class DirectionsException implements Exception {
  DirectionsException(this.message, {this.networkUnavailable = false});

  final String message;
  final bool networkUnavailable;

  @override
  String toString() => 'DirectionsException: $message';
}
