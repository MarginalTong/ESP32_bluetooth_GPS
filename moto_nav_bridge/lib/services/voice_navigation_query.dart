import '../models/nav_state.dart';
import '../models/lat_lng.dart';
import '../models/route_candidate.dart';
import 'dart:math' as math;
import 'navigation_voice.dart';

/// Read-only local commands. No model-generated driving advice, mutations or
/// uploads. Re-evaluate validity at answer time, not when recording starts.
String answerVoiceQuery(String transcript,
    {required bool english,
    required NavState? state,
    required bool reliable,
    bool navigationActive = true,
    int? remainingSeconds}) {
  final text = _normalizedVoiceQuery(transcript);
  const turn = {
    'doiturnrightatthenextjunction',
    'whatsthenextturn',
    '下一步怎么走',
    '下一个路口右转吗',
    '下个路口右转吗'
  };
  const eta = {
    'eta',
    'howlonguntilarrival',
    'howlonguntiliarrive',
    '还有多久到',
    '还有多久到达'
  };
  if (isVoiceRepeatRequest(transcript) || turn.contains(text)) {
    if (!navigationActive) {
      return english
          ? 'Start navigation first, then I can repeat the next instruction.'
          : '请先开始导航，然后我才能重复下一步指令。';
    }
    if (!reliable || state == null) {
      return english
          ? 'I cannot confirm the current instruction. Navigation or location is not ready.'
          : '当前导航或定位尚未就绪，暂时无法确认下一步指令。';
    }
    return NavigationVoice.instruction(state, english: english) ??
        (english
            ? 'The route is updating. I cannot confirm the turn yet.'
            : '路线正在更新，暂时无法确认转弯。');
  }
  if (eta.contains(text)) {
    if (!navigationActive) {
      return english
          ? 'Start navigation first, then I can estimate the remaining time.'
          : '请先开始导航，然后我才能估算剩余时间。';
    }
    if (remainingSeconds != null && remainingSeconds > 0) {
      final minutes = math.max(1, (remainingSeconds / 60).ceil());
      return english
          ? 'About $minutes minutes remain on the current route. Traffic may change this estimate.'
          : '按当前路线估算还要约$minutes分钟，路况变化可能影响时间。';
    }
    return english
        ? 'A reliable remaining travel time is not available yet.'
        : '目前还没有可靠的剩余行程时间，暂时无法回答。';
  }
  return english
      ? 'No supported navigation query was recognized. Your route has not changed.'
      : '未识别到支持的导航查询，路线没有改变。';
}

String _normalizedVoiceQuery(String transcript) =>
    transcript.toLowerCase().replaceAll(RegExp(r'[\s.,!?，。！？]'), '');

bool isVoiceRepeatRequest(String transcript) => const {
      'repeat',
      'next_turn',
      'repeattheinstruction',
      'sayitagain',
      'repeatthat',
      'onemoretime',
      '再说一遍',
      '再说一次',
      '再讲一遍',
      '重复指令',
      '重复一下',
    }.contains(_normalizedVoiceQuery(transcript));

/// Scales the route provider's travel-time estimate by distance still ahead on
/// this same route. Never uses a straight line to the destination or a new
/// alternative route, which could give a misleading answer at junctions.
int? estimateRemainingRouteSeconds(
    RouteCandidate route, LatLng position, int stepIndex,
    {double maxDistanceMeters = 25}) {
  final totalSeconds = route.expectedTravelTimeSeconds;
  if (totalSeconds == null ||
      totalSeconds <= 0 ||
      stepIndex < 0 ||
      stepIndex >= route.steps.length) {
    return null;
  }

  var fullLength = 0.0;
  var laterLength = 0.0;
  var currentLength = 0.0;
  var currentRemaining = 0.0;
  var nearestMeters = double.infinity;

  for (var step = 0; step < route.steps.length; step++) {
    final points = route.steps[step].geometry.length >= 2
        ? route.steps[step].geometry
        : [route.steps[step].start, route.steps[step].end];
    var stepLength = 0.0;
    var bestRemaining = 0.0;
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      final length = a.distanceTo(b);
      if (length < 0.1) continue;
      if (step == stepIndex) {
        final scale = math.cos(position.latitude * math.pi / 180);
        final ax = (a.longitude - position.longitude) * scale;
        final ay = a.latitude - position.latitude;
        final dx = (b.longitude - a.longitude) * scale;
        final dy = b.latitude - a.latitude;
        final denominator = dx * dx + dy * dy;
        final t = denominator == 0
            ? 0.0
            : (-(ax * dx + ay * dy) / denominator).clamp(0.0, 1.0);
        final projected = LatLng(a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t);
        final distance = position.distanceTo(projected);
        if (distance < nearestMeters) {
          nearestMeters = distance;
          bestRemaining = stepLength + length * t;
        }
      }
      stepLength += length;
    }
    fullLength += stepLength;
    if (step == stepIndex) {
      currentLength = stepLength;
      currentRemaining = bestRemaining;
    } else if (step > stepIndex) {
      laterLength += stepLength;
    }
  }
  if (fullLength <= 0 || nearestMeters > maxDistanceMeters) return null;
  final remainingLength = currentLength - currentRemaining + laterLength;
  return math.max(1, (totalSeconds * remainingLength / fullLength).ceil());
}
