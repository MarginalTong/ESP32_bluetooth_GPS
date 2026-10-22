/// Thrown when route planning fails or returns no usable route.
class DirectionsException implements Exception {
  DirectionsException(this.message);

  final String message;

  @override
  String toString() => 'DirectionsException: $message';
}
