/// When to try the bound display again after its link dropped.
///
/// A rider cannot tap "Connect" on the road, so the App never gives up while
/// the user wants the display connected: quick retries for a radio glitch,
/// then a steady pace while the display restarts or is switched back on,
/// then a slow one that costs little battery if it stays off.
class BleReconnectPolicy {
  const BleReconnectPolicy();

  /// How long each retry scans for the display.
  static const scanTimeout = Duration(seconds: 8);

  /// Seconds before the first retries: a transient drop usually recovers.
  static const _quick = [1, 2, 4, 8];

  /// Wait between the steady retries.
  static const _steady = Duration(seconds: 10);

  /// Steady retries before slowing down: with [scanTimeout] about 5 minutes,
  /// longer than a display restart or a fuel stop with the ignition off.
  static const _steadyAttempts = 16;

  /// Wait between retries after that, for as long as the display is wanted.
  static const _slow = Duration(seconds: 30);

  /// Wait before retry number [attempt] (0 for the first after a drop).
  Duration delay(int attempt) {
    if (attempt < _quick.length) {
      return Duration(seconds: _quick[attempt < 0 ? 0 : attempt]);
    }
    return attempt < _quick.length + _steadyAttempts ? _steady : _slow;
  }
}
