import '../models/lat_lng.dart';
import '../models/route_step.dart';
import 'route_geometry.dart';

/// Stabilizes measured along-road progress, never extrapolates it. The engine
/// supplies its constrained segment match; the preview must not independently
/// rematch against a later hairpin or another arm of a junction.
class RoutePreviewProgress {
  /// Previous vertices inside a 40 m context window, even across several
  /// short maneuvers. Keep one boundary vertex so no artificial chord joins
  /// the retained context to the current step.
  static List<LatLng> behind(List<RouteStep> steps, int current) {
    final reverse = <LatLng>[];
    var length = 0.0;
    for (var i = current - 1; i >= 0 && length < 40; i--) {
      final step = steps[i];
      final points = step.geometry.length >= 2
          ? step.geometry
          : [step.start, step.end];
      for (final point in points.reversed) {
        if (reverse.isNotEmpty) length += reverse.last.distanceTo(point);
        reverse.add(point);
        if (length >= 40) break;
      }
    }
    return reverse.reversed.toList(growable: false);
  }

  int _step = -1;
  double _along = 0;
  List<double> _prefix = const [];
  ClosestSegment? _last;

  ClosestSegment update(
    LatLng fix,
    List<LatLng> points,
    int step,
    ClosestSegment measured,
  ) {
    if (_step != step) {
      _step = step;
      _last = null;
      _prefix = [0];
      for (var i = 1; i < points.length; i++) {
        _prefix.add(_prefix.last + points[i - 1].distanceTo(points[i]));
      }
    }
    final along =
        _prefix[measured.segmentIndex] +
        points[measured.segmentIndex].distanceTo(measured.projected);
    // At rest hold sub-3 m noise; moving fixes advance immediately. Small
    // backwards jitter cannot resurrect passed geometry. A real retreat over
    // 5 m is accepted, leaving reverse/off-route decisions to the engine.
    final stationary =
        fix is NavigationFix &&
        fix.speed.isFinite &&
        fix.speed >= 0 &&
        fix.speed < 0.5;
    if (_last != null &&
        ((stationary && (along - _along).abs() < 3) ||
            (along < _along && _along - along < 5))) {
      return ClosestSegment(
        segmentIndex: _last!.segmentIndex,
        projected: _last!.projected,
        distanceMeters: measured.distanceMeters,
      );
    }
    _along = along;
    _last = measured;
    return measured;
  }
}
