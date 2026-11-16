import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Notices a link that the phone still reports as connected but that no
/// longer carries writes. This happens when the display restarts and iOS has
/// not noticed yet: every write then times out, and nothing recovers until
/// the stale connection is dropped and made again.
class BleLinkHealth {
  /// Seconds to wait for the display to acknowledge a navigation write. A
  /// healthy write takes well under a second; the library default of 15 s
  /// would leave the display without updates for most of a minute.
  static const writeTimeoutSeconds = 5;

  /// Unanswered writes in a row before the link is treated as dead. One or
  /// two can be lost to interference on a working link.
  static const failuresBeforeReset = 3;

  int _failures = 0;

  /// Call when a write was acknowledged, or a new connection was made.
  void reset() => _failures = 0;

  /// Records a failed write and returns true when the connection should be
  /// dropped and made again. A write the display answered with an error
  /// ([linkError] false) proves the link works, so it never counts.
  bool writeFailed({required bool linkError}) {
    if (!linkError) {
      _failures = 0;
      return false;
    }
    _failures++;
    if (_failures < failuresBeforeReset) return false;
    _failures = 0;
    return true;
  }

  /// Whether [error] means the write got no answer at all (timed out, or
  /// the link was already gone), as opposed to the display refusing it.
  static bool isLinkError(Object error) {
    if (error is TimeoutException) return true;
    return error is FlutterBluePlusException &&
        error.platform == ErrorPlatform.fbp &&
        (error.code == FbpErrorCode.timeout.index ||
            error.code == FbpErrorCode.deviceIsDisconnected.index);
  }
}
