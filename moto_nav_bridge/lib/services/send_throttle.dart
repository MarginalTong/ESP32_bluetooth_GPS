import '../models/nav_state.dart';

/// Decides whether a freshly-computed [NavState] is worth writing to the BLE
/// characteristic, to avoid flooding the link (the firmware refreshes very fast
/// on its own; we only need to push meaningful changes).
///
/// Sends when ANY of:
///   - the direction changed, OR
///   - the distance changed by >= [minDistanceDeltaMeters], OR
///   - at least [minInterval] has elapsed since the last send (heartbeat).
///
/// Pure and time-injectable so it can be unit-tested deterministically.
class SendThrottle {
  SendThrottle({
    this.minDistanceDeltaMeters = 5,
    this.minInterval = const Duration(seconds: 1),
  });

  final int minDistanceDeltaMeters;
  final Duration minInterval;

  NavState? _last;
  DateTime? _lastSentAt;

  /// Returns true if [candidate] should be sent at time [now].
  bool shouldSend(NavState candidate, DateTime now) {
    final last = _last;
    final lastAt = _lastSentAt;

    if (last == null || lastAt == null) return true;
    if (candidate.direction != last.direction) return true;
    if (!_listEquals(candidate.routePreviewPoints, last.routePreviewPoints)) {
      return true;
    }
    if (!_listEquals(
      candidate.sideRoadPreviewPoints,
      last.sideRoadPreviewPoints,
    )) {
      return true;
    }
    if ((candidate.distanceMeters - last.distanceMeters).abs() >=
        minDistanceDeltaMeters) {
      return true;
    }
    if (now.difference(lastAt) >= minInterval) return true;
    return false;
  }

  /// Records that [state] was sent at [now]. Call only after a successful write.
  void markSent(NavState state, DateTime now) {
    _last = state;
    _lastSentAt = now;
  }

  void reset() {
    _last = null;
    _lastSentAt = null;
  }
}

bool _listEquals(List<int> a, List<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
