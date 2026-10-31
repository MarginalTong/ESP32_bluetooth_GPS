import '../../models/device_direction.dart';
import '../../models/nav_state.dart';
import '../../models/route_step.dart';
import 'guidance_phrases.dart';
import 'guidance_route.dart';

/// Configurable announcement policy.
class VoiceGuidancePolicy {
  const VoiceGuidancePolicy({
    this.curveWarnings = true,
    this.minGap = const Duration(seconds: 3),
    this.rerouteCooldown = const Duration(seconds: 20),
  });

  /// Assistive only: never a substitute for watching the road, and never a
  /// speed advice derived from map curvature.
  final bool curveWarnings;

  /// Least time between two non-urgent announcements.
  final Duration minGap;

  /// Least time between two "off route" announcements.
  final Duration rerouteCooldown;
}

/// Everything the planner needs from one navigation update.
class GuidanceInput {
  const GuidanceInput({
    required this.route,
    required this.steps,
    required this.stepIndex,
    required this.state,
    required this.now,
    this.reliable = true,
    this.speedMps,
    this.accuracyMeters,
    this.rerouteFailed = false,
    this.speaking = false,
  });

  /// Identity of the route being followed; a new object means a new route.
  final Object route;
  final List<RouteStep> steps;
  final int stepIndex;

  /// What the display shows now. Its direction always wins over route data.
  final NavState state;
  final DateTime now;

  /// Fresh, accurate fix on a valid route (no turn announcements otherwise).
  final bool reliable;
  final double? speedMps;
  final double? accuracyMeters;
  final bool rerouteFailed;

  /// A previous announcement is still playing.
  final bool speaking;
}

enum GuidancePriority { info, maneuver, urgent }

class GuidanceUtterance {
  const GuidanceUtterance(this.text, this.priority);
  final String text;
  final GuidancePriority priority;

  @override
  String toString() => 'GuidanceUtterance($priority, $text)';
}

/// Layer 2: decides when to speak and what. Pure and time-injected; the
/// caller speaks the returned text. Each maneuver has three stages (far,
/// prepare, final); a stage is spoken at most once, and only nearer stages
/// can follow, so GPS jitter can never repeat an announcement.
class VoiceGuidancePlanner {
  VoiceGuidancePlanner({this.policy = const VoiceGuidancePolicy()});

  final VoiceGuidancePolicy policy;

  static const int _none = 3, _far = 2, _prepare = 1, _final = 0;
  static const double _defaultSpeed = 8; // m/s, when the fix has no speed

  Object? _route;
  GuidanceRoute? _guidance;
  final Map<int, int> _spokenStage = {};
  final Set<int> _announcedAsFollowUp = {};
  final Map<int, DateTime> _stageSpokenAt = {};
  final Set<int> _curvesWarned = {};
  DateTime? _lastSpokenAt;
  double? _speed;
  bool _inReroute = false;
  bool _rerouteFailureSpoken = false;
  DateTime? _lastRerouteNoticeAt;
  bool _arrivedSpoken = false;

  void reset() {
    _route = null;
    _guidance = null;
    _clearRouteState();
    _lastSpokenAt = null;
    _speed = null;
    _inReroute = false;
    _rerouteFailureSpoken = false;
    _lastRerouteNoticeAt = null;
  }

  void _clearRouteState() {
    _spokenStage.clear();
    _announcedAsFollowUp.clear();
    _stageSpokenAt.clear();
    _curvesWarned.clear();
    _arrivedSpoken = false;
  }

  GuidanceUtterance? next(GuidanceInput input, {required bool english}) {
    final phrases = GuidancePhrases(english: english);
    final state = input.state;
    _updateSpeed(input.speedMps);

    // Off route: tell the rider once per episode, before anything else.
    if (state.rerouting) {
      if (!_inReroute) {
        _inReroute = true;
        _rerouteFailureSpoken = false;
        final last = _lastRerouteNoticeAt;
        if (last == null || input.now.difference(last) >= policy.rerouteCooldown) {
          _lastRerouteNoticeAt = input.now;
          return _speak(phrases.rerouting, GuidancePriority.urgent, input.now);
        }
      }
      if (input.rerouteFailed && !_rerouteFailureSpoken && !input.speaking) {
        _rerouteFailureSpoken = true;
        return _speak(phrases.rerouteFailed, GuidancePriority.urgent, input.now);
      }
      return null;
    }
    _inReroute = false;

    if (!identical(input.route, _route)) {
      _route = input.route;
      _guidance = GuidanceRoute.fromSteps(input.steps);
      _clearRouteState();
    }
    final guidance = _guidance!;

    if (state.direction == DeviceDirection.arrived) {
      if (_arrivedSpoken) return null;
      _arrivedSpoken = true;
      return _speak(phrases.arrived, GuidancePriority.urgent, input.now);
    }
    if (state.direction == DeviceDirection.stop || !input.reliable) return null;

    final upcoming = guidance.upcoming(input.stepIndex);
    if (upcoming == null) return null;
    final atDestination = upcoming.kind == ManeuverKind.destination;
    // The display direction is authoritative: route detail is used only when
    // it agrees with it. Agreeing data decides (a straight-on ramp or fork is
    // announced, a plain "continue" is not); otherwise only a real turn is.
    final consistent = atDestination || upcoming.direction == state.direction;
    final announced =
        consistent ? !upcoming.isSilent : state.direction != DeviceDirection.up;
    if (!announced) return _maybeCurves(input, guidance, phrases);
    final maneuver = consistent ? upcoming : null;
    final speech = _maneuverSpeech(input, guidance, phrases, upcoming, maneuver);
    return speech ?? _maybeCurves(input, guidance, phrases);
  }

  GuidanceUtterance? _maneuverSpeech(
    GuidanceInput input,
    GuidanceRoute guidance,
    GuidancePhrases phrases,
    GuidanceManeuver upcoming,
    GuidanceManeuver? maneuver,
  ) {
    final state = input.state;
    final d = state.distanceMeters.toDouble();
    final speed = _speed ?? _defaultSpeed;
    final complex = (maneuver?.isComplex ?? false) || _followUp(guidance, maneuver, speed) != null;
    final t = _thresholds(speed, input.accuracyMeters ?? 0, complex);
    final followUpOnly = _announcedAsFollowUp.contains(upcoming.index);

    final stage = d <= t.$3
        ? _final
        : d <= t.$2 && !followUpOnly
            ? _prepare
            : d <= t.$1 && speed >= 6 && !followUpOnly
                ? _far
                : _none;
    final spoken = _spokenStage[upcoming.index] ?? _none;
    if (stage == _none || stage >= spoken) return null;

    if (stage == _final && upcoming.kind == ManeuverKind.destination) {
      // "You have arrived" follows a few metres later.
      _spokenStage[upcoming.index] = _final;
      return null;
    }
    if (stage == _final) {
      // A prepare announcement a moment ago already said it: stay quiet.
      final prepared = _stageSpokenAt[upcoming.index];
      if (spoken == _prepare &&
          prepared != null &&
          input.now.difference(prepared) < const Duration(seconds: 4)) {
        _spokenStage[upcoming.index] = _final;
        return null;
      }
    } else {
      if (input.speaking) return null; // re-evaluated with fresh distance later
      final last = _lastSpokenAt;
      if (last != null && input.now.difference(last) < policy.minGap) return null;
    }

    final direction = upcoming.kind == ManeuverKind.destination
        ? DeviceDirection.arrived
        : state.direction;
    final action = phrases.action(direction, maneuver);
    final follow = _followUp(guidance, maneuver, speed);
    final then = follow == null ? '' : phrases.then(follow.maneuver, follow.gapMeters);
    if (follow != null) _announcedAsFollowUp.add(follow.maneuver.index);

    final String body;
    if (stage == _final && spoken != _none) {
      body = '$action$then'; // short final reminder after an earlier one
    } else if (followUpOnly) {
      body = action; // already announced as "then ..." with the maneuver before
    } else {
      final onto = spoken == _none ? phrases.onto(maneuver, direction) : '';
      body = '${phrases.distance(state.distanceMeters)}$action$onto$then';
    }
    _spokenStage[upcoming.index] = stage;
    _stageSpokenAt[upcoming.index] = input.now;
    return _speak(phrases.sentence(body),
        stage == _final ? GuidancePriority.urgent : GuidancePriority.maneuver, input.now);
  }

  /// The next announced maneuver when it comes too soon for its own
  /// announcement. Only for verified maneuvers: missing data never chains.
  ({GuidanceManeuver maneuver, double gapMeters})? _followUp(
      GuidanceRoute guidance, GuidanceManeuver? maneuver, double speed) {
    if (maneuver == null || maneuver.kind == ManeuverKind.destination) return null;
    final next = guidance.following(maneuver);
    if (next == null) return null;
    // A roundabout's own exit is part of its entry announcement.
    if (maneuver.kind == ManeuverKind.roundaboutEnter &&
        next.maneuver.kind == ManeuverKind.roundaboutExit) {
      return null;
    }
    final limit = (speed * 6).clamp(60.0, 180.0);
    return next.gapMeters <= limit ? next : null;
  }

  /// (far, prepare, final) trigger distances in metres: about 30 s, 12 s and
  /// 4.5 s ahead, earlier for complex junctions and imprecise fixes.
  (double, double, double) _thresholds(double speed, double accuracy, bool complex) {
    final factor = complex ? 1.25 : 1.0;
    final margin = accuracy.clamp(0.0, 30.0) * 0.5;
    return (
      (speed * 30).clamp(250.0, 1500.0) * factor + margin,
      (speed * 12).clamp(80.0, 500.0) * factor + margin,
      (speed * 4.5).clamp(20.0, 120.0) + margin * 0.5,
    );
  }

  GuidanceUtterance? _maybeCurves(
      GuidanceInput input, GuidanceRoute guidance, GuidancePhrases phrases) {
    if (!policy.curveWarnings || !input.reliable || input.speaking) return null;
    final speed = _speed ?? 0;
    if (speed < 5) return null;
    final last = _lastSpokenAt;
    if (last != null && input.now.difference(last) < const Duration(seconds: 4)) {
      return null;
    }
    if (input.stepIndex < 0 || input.stepIndex >= guidance.stepEndAlong.length) {
      return null;
    }
    final rider = guidance.stepEndAlong[input.stepIndex] - input.state.distanceMeters;
    final reach = (speed * 10).clamp(80.0, 300.0);
    for (var i = 0; i < guidance.curves.length; i++) {
      if (_curvesWarned.contains(i)) continue;
      final ahead = guidance.curves[i].startAlong - rider;
      if (ahead <= 0 || ahead > reach) continue;
      _curvesWarned.add(i);
      // A maneuver right before or inside the bends matters more.
      final maneuverAhead = input.state.direction != DeviceDirection.up &&
          input.state.distanceMeters < ahead + 100;
      if (maneuverAhead) return null;
      return _speak(phrases.curves, GuidancePriority.info, input.now);
    }
    return null;
  }

  void _updateSpeed(double? speed) {
    if (speed == null || !speed.isFinite || speed < 0 || speed > 80) return;
    _speed = _speed == null ? speed : _speed! + (speed - _speed!) * 0.5;
  }

  GuidanceUtterance _speak(String text, GuidancePriority priority, DateTime now) {
    _lastSpokenAt = now;
    return GuidanceUtterance(text, priority);
  }
}
