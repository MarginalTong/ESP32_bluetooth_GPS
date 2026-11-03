import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The in-app language choice; [system] follows the phone's language.
enum AppLanguage {
  system,
  en,
  zh;

  static const storageKey = 'navio.app_language';

  static AppLanguage fromStorage(String? value) =>
      AppLanguage.values.firstWhere(
        (language) => language.name == value,
        orElse: () => AppLanguage.system,
      );
}

/// Rebuilds everything that reads [AppText.of] when the language changes.
class AppLanguageScope extends InheritedNotifier<ValueNotifier<AppLanguage>> {
  AppLanguageScope({super.key, required super.child})
    : super(notifier: AppText.selected);
}

class AppText {
  const AppText._(this.isEnglish);

  final bool isEnglish;

  static const zh = AppText._(false);
  static const en = AppText._(true);

  static final selected = ValueNotifier(AppLanguage.system);

  static AppText of(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<AppLanguageScope>();
    final locale =
        View.maybeOf(context)?.platformDispatcher.locale ??
        ui.PlatformDispatcher.instance.locale;
    return _resolve(locale);
  }

  /// For code without a BuildContext (services, native map arguments).
  static AppText get current => _resolve(ui.PlatformDispatcher.instance.locale);

  static AppText _resolve(ui.Locale locale) => switch (selected.value) {
    AppLanguage.en => en,
    AppLanguage.zh => zh,
    AppLanguage.system => fromLocale(locale),
  };

  static AppText fromLocale(ui.Locale locale) =>
      locale.languageCode.toLowerCase().startsWith('en') ? en : zh;

  String get languageCode => isEnglish ? 'en' : 'zh';
  String get mapTab => isEnglish ? 'Map' : '地图';
  String get cancelAction => isEnglish ? 'Cancel' : '取消';
  String get confirmAction => isEnglish ? 'Confirm' : '确认';
  String get myDevices => isEnglish ? 'My devices' : '我的设备';
  String get noBoundDevice => isEnglish ? 'No display bound' : '尚未绑定屏幕';
  String get disconnectDevice => isEnglish ? 'Disconnect' : '断开连接';
  String get disconnectHint =>
      isEnglish ? 'Keep binding for the next connection.' : '保留绑定，下次仍连接这块屏幕。';
  String get replaceDevice => isEnglish ? 'Change display' : '更换屏幕';
  String get replaceHint => isEnglish
      ? 'Forget this display, then pair another. Replug the new display first.'
      : '清除本机绑定，再配对新屏幕。请先给新屏幕重新插电。';
  String get pairingInProgress => isEnglish ? 'Pairing…' : '正在配对…';
  String get pairingInProgressHint =>
      isEnglish ? 'Keep your phone near the display.' : '请让手机靠近屏幕。';
  String get pairingWindowClosedTitle =>
      isEnglish ? 'Replug the display' : '请重新插电';
  String get replugToPair => isEnglish
      ? 'For security, a display pairs only within 60 seconds of being powered on. Unplug it, plug it back in, then try again.'
      : '为了安全，屏幕只在通电后 60 秒内允许配对。请拔掉电源再插上，然后重试。';
  String get forgetDevice => isEnglish ? 'Forget device' : '忘记设备';
  String get forgetHint => isEnglish
      ? 'Clear local binding without connecting another display.'
      : '清除本机绑定，不立即连接新设备。';
  String get bindingScope => isEnglish
      ? 'Binding is saved on this phone only. Forgetting does not revoke access on other phones.'
      : '绑定仅保存在本机；忘记设备不会撤销其他手机的连接权限。';
  String get selectDisplay => isEnglish ? 'Select your display' : '选择你的导航屏';
  String get pressBoot =>
      isEnglish ? 'Press BOOT on the display' : '请按屏幕上的 BOOT 按钮';
  String get bootHint => isEnglish
      ? 'Press BOOT once on the display you selected. No code needed.'
      : '在你选中的屏幕上按一次 BOOT，无需输入验证码。';
  String get deviceActionFailed =>
      isEnglish ? 'Device operation failed. Please try again.' : '设备操作失败，请重试。';

  String get readyToGo => isEnglish ? 'Ready to go' : '准备出发';
  String get connectDevice => isEnglish ? 'Connect device' : '连接设备';
  String get tapToConnect => isEnglish ? 'Tap to connect' : '点按连接导航屏';
  String get connectingDisplay => isEnglish ? 'Connecting display' : '正在连接导航屏';
  String get displayNotConnected =>
      isEnglish ? 'Display not connected' : '导航屏未连接';
  String get searchingDevice => isEnglish ? 'Searching…' : '正在搜索设备…';
  String get connecting => isEnglish ? 'Connecting…' : '正在连接…';
  String get deviceConnected => isEnglish ? 'Device connected' : '设备已连接';
  String get displayUpdateInterrupted =>
      isEnglish ? 'Display update interrupted' : '屏幕更新中断';
  String get reconnectDisplayHint =>
      isEnglish ? 'Reconnect the display' : '请重新连接导航屏';
  String get deviceConnectionIssue =>
      isEnglish ? 'Display problem' : '导航屏连接异常';
  String get displayOffline => isEnglish ? 'Display offline' : '导航屏离线';
  String get displayOfflineHint =>
      isEnglish ? 'Turn it on and keep it nearby' : '请开机并靠近手机';
  String get displayDisconnected =>
      isEnglish ? 'Display disconnected' : '导航屏已断开';
  String get displayDisconnectedHint =>
      isEnglish ? 'Reconnecting automatically' : '正在自动重连';
  String get bluetoothOff => isEnglish ? 'Bluetooth is off' : '蓝牙未开启';
  String get bluetoothOffHint =>
      isEnglish ? 'Turn it on to connect' : '打开蓝牙后即可连接';
  String get pairDisplayAgain =>
      isEnglish ? 'Pair display again' : '请重新配对导航屏';
  String get pairDisplayAgainHint =>
      isEnglish ? 'Replug the display, then tap' : '屏幕重新插电后点按';

  /// "45 s" / "3 min" / "2 h" (English) or "45 秒" / "3 分钟" / "2 小时".
  String _age(Duration age) {
    if (age.inSeconds < 60) {
      final s = age.inSeconds < 1 ? 1 : age.inSeconds;
      return isEnglish ? '$s s' : '$s 秒';
    }
    if (age.inMinutes < 60) {
      return isEnglish ? '${age.inMinutes} min' : '${age.inMinutes} 分钟';
    }
    return isEnglish ? '${age.inHours} h' : '${age.inHours} 小时';
  }

  String writeFailedAgo(Duration age) => isEnglish
      ? 'Display write failed ${_age(age)} ago'
      : '屏幕写入失败（${_age(age)}前）';
  String get deviceDetailsHint =>
      isEnglish ? 'See My devices for details' : '请在“我的设备”查看详情';

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
  String get endNavigation => isEnglish ? 'End navigation' : '结束导航';
  String get endAndDisconnect =>
      isEnglish ? 'End navigation and disconnect' : '结束并断开导航';

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
