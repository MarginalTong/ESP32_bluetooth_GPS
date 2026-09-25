import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

class AppText {
  const AppText._(this.isEnglish);

  final bool isEnglish;

  static const zh = AppText._(false);
  static const en = AppText._(true);

  static AppText of(BuildContext context) {
    final locale = View.maybeOf(context)?.platformDispatcher.locale ??
        ui.PlatformDispatcher.instance.locale;
    return fromLocale(locale);
  }

  static AppText get system =>
      fromLocale(ui.PlatformDispatcher.instance.locale);

  static AppText fromLocale(ui.Locale locale) =>
      locale.languageCode.toLowerCase().startsWith('en') ? en : zh;

  String get languageCode => isEnglish ? 'en' : 'zh';

  String get readyToGo => isEnglish ? 'Ready to go' : '准备出发';
  String get connectDevice => isEnglish ? 'Connect device' : '连接设备';
  String get searchingDevice => isEnglish ? 'Searching…' : '正在搜索设备…';
  String get connecting => isEnglish ? 'Connecting…' : '正在连接…';
  String get deviceConnected => isEnglish ? 'Device connected' : '设备已连接';

  String get mapPoint => isEnglish ? 'Map point' : '地图选点';
  String get destination => isEnglish ? 'Destination' : '目的地';
  String get searchPlaceAddressBusiness =>
      isEnglish ? 'Search place, address or business' : '搜索地点、地址或商家';
  String get connectNavScreenFirst =>
      isEnglish ? 'Connect navigation screen first' : '请先连接导航屏';
  String get chooseDestinationFirst =>
      isEnglish ? 'Choose a destination first' : '请先选择目的地';
  String get startNavigation => isEnglish ? 'Start navigation' : '开始导航';
  String get planningRoute => isEnglish ? 'Planning route…' : '路线规划中…';
  String get planningRouteShort => isEnglish ? 'Planning…' : '规划中…';
  String get resumeNavigation => isEnglish ? 'Resume navigation' : '继续导航';
  String get pauseNavigation => isEnglish ? 'Pause navigation' : '暂停导航';
  String get endAndDisconnect =>
      isEnglish ? 'End navigation and disconnect' : '结束导航并断开';

  String get nextTurn => isEnglish ? 'Next turn' : '后续路口';
  String get destinationReached => isEnglish ? 'Destination reached' : '目的地已到达';
  String get connectDeviceAndEnterDestination =>
      isEnglish ? 'Connect device and choose a destination' : '连接设备并输入目的地坐标';
  String get keepStraight => isEnglish ? 'Continue straight' : '继续直行';
  String get turnLeftAhead => isEnglish ? 'Turn left ahead' : '前方左转';
  String get turnRightAhead => isEnglish ? 'Turn right ahead' : '前方右转';
  String get bearLeft => isEnglish ? 'Keep left' : '靠左行驶';
  String get bearRight => isEnglish ? 'Keep right' : '靠右行驶';
  String get uTurnAhead => isEnglish ? 'Make a U-turn ahead' : '前方掉头';
  String get navigationPaused => isEnglish ? 'Navigation paused' : '导航已暂停';
  String get arrived => isEnglish ? 'Arrived' : '已到达';

  String get searchDestination => isEnglish ? 'Search destination' : '搜索目的地';
  String get enterPlaceAddressBusiness =>
      isEnglish ? 'Enter a place, address, or business' : '输入地点、地址或商家名称';
  String get noMatchingPlaces => isEnglish
      ? 'No matching places. Try another keyword.'
      : '没找到匹配地点，换个关键词试试';
  String get candidateHasNoCoordinate => isEnglish
      ? 'This result has no navigation coordinate. Try another one.'
      : '这个候选没有可导航坐标，换一个试试';
  String get recentSearches => isEnglish ? 'Recent searches' : '最近搜索';
  String get clear => isEnglish ? 'Clear' : '清空';
  String get whereTo => isEnglish ? 'Where to?' : '想去哪里？';
  String get searchExamples => isEnglish
      ? 'For example: Opera House, airport, coffee shop'
      : '例如：悉尼歌剧院、机场、咖啡店';
  String get iosMapKitOnly => isEnglish
      ? 'Map display is currently iOS MapKit only'
      : '地图显示目前只接了 iOS MapKit';

  String get rerouting => isEnglish ? 'Rerouting…' : '正在重新规划路线';
  String get offRouteRerouting =>
      isEnglish ? 'Off route, rerouting…' : '已偏离路线，正在重新规划';
  String rerouteFailed(Object error) =>
      isEnglish ? 'Reroute failed: $error' : '重新规划失败: $error';
  String get gpsSignalLost => isEnglish ? 'GPS signal lost' : 'GPS signal lost';

  String get noDrivingRoute =>
      isEnglish ? 'No drivable route found' : '没有找到可驾驶路线';
  String get placeAutocompleteFailed =>
      isEnglish ? 'Place autocomplete failed' : '地点联想失败';
  String get placeSearchFailed => isEnglish ? 'Place search failed' : '地点搜索失败';
  String get routePlanningFailed =>
      isEnglish ? 'Route planning failed' : '路线规划失败';
  String routeName(int index) => isEnglish
      ? (index == 0 ? 'Recommended route' : 'Route ${index + 1}')
      : (index == 0 ? '推荐路线' : '路线 ${index + 1}');

  String durationMinutes(int minutes) =>
      isEnglish ? '$minutes min' : '约 $minutes 分钟';

  String durationHoursMinutes(int hours, int minutes) {
    if (isEnglish) {
      return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
    }
    return minutes == 0 ? '约 $hours 小时' : '约 $hours 小时 $minutes 分钟';
  }

  String etaSummary(String duration, String arrivalTime) =>
      isEnglish ? '$duration · $arrivalTime' : '$duration · $arrivalTime 到达';
}
