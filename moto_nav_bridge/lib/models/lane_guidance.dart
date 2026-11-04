enum RoadSide { left, right }

/// Which lanes to use for a maneuver, as the routing data marks them. Lanes
/// are counted from the left; [first]..[last] is one contiguous run that is
/// neither empty nor every lane, so it always tells the rider something.
class LaneGuidance {
  const LaneGuidance._(this.laneCount, this.first, this.last);

  /// More lanes than this is not something a rider can count while riding.
  static const maxLanes = 8;

  /// From one flag per lane, left to right. Null when the advice would be
  /// empty, cover every lane, or skip a lane in between.
  static LaneGuidance? fromFlags(List<bool> use) {
    if (use.length < 2 || use.length > maxLanes) return null;
    final first = use.indexOf(true);
    final last = use.lastIndexOf(true);
    if (first < 0) return null;
    if (first == 0 && last == use.length - 1) return null;
    if (use.sublist(first, last + 1).contains(false)) return null;
    return LaneGuidance._(use.length, first, last);
  }

  final int laneCount;
  final int first;
  final int last;

  int get count => last - first + 1;

  /// Lanes between the run and each edge of the road.
  int get fromLeft => first;
  int get fromRight => laneCount - 1 - last;

  @override
  bool operator ==(Object other) =>
      other is LaneGuidance &&
      other.laneCount == laneCount &&
      other.first == first &&
      other.last == last;

  @override
  int get hashCode => Object.hash(laneCount, first, last);

  @override
  String toString() => 'LaneGuidance($first..$last of $laneCount)';
}
