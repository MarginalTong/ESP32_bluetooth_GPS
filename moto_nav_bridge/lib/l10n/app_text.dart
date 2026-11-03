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
  String get deviceConnectionIssue => isEnglish ? 'Display problem' : '导航屏连接异常';
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
  String get pairDisplayAgain => isEnglish ? 'Pair display again' : '请重新配对导航屏';
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

  // Extracted from widgets (maintainability rules: all UI text lives here).
  String get enterValidEmail => isEnglish ? 'Enter a valid email.' : '请输入有效邮箱。';
  String get passwordRuleError => isEnglish
      ? 'Use at least 6 characters and matching passwords.'
      : '密码至少 6 位，两次输入需一致。';
  String get requestCompletedCheckEmail => isEnglish
      ? 'Request completed. Check your email if a code is required.'
      : '操作已完成，如需验证码请查收邮件。';
  String get localSettingsChangedDuring => isEnglish
      ? 'Local settings changed during sync. Nothing was replaced; try again.'
      : '同步期间本机资料被修改，未覆盖任何资料，请重试。';
  String get cloudDataChangedOn => isEnglish
      ? 'Cloud data changed on another device. Restore it before uploading.'
      : '另一台设备已更新云端资料，请先恢复云端资料，再上传。';
  String get finishNavigationBeforeChanging => isEnglish
      ? 'Finish navigation before changing account data.'
      : '请先结束导航，再更改账号资料。';
  String get localDataCouldNot => isEnglish
      ? 'Local data could not be saved. Please try again.'
      : '本机资料保存失败，请重试。';
  String get sessionNeedsAttentionSign => isEnglish
      ? 'Your session needs attention. Sign in again.'
      : '登录状态已失效，请重新登录。';
  String get appleAuthorizationCouldNot => isEnglish
      ? 'Apple authorization could not be saved. Try Apple sign-in again.'
      : 'Apple 授权保存失败，请重新使用 Apple 登录。';
  String get googleSignInNot => isEnglish
      ? 'Google sign-in is not configured for this build. Use email for now.'
      : '此版本尚未配置好 Google 登录，请暂时使用邮箱登录。';
  String get googleSignInDid => isEnglish
      ? 'Google sign-in did not complete. Check your connection and try again.'
      : 'Google 登录未完成，请检查网络后重试。';
  String get requestFailedCheckCredentials => isEnglish
      ? 'Request failed. Check your credentials, code and connection, then retry.'
      : '操作失败，请检查邮箱、密码、验证码或网络后重试。';
  String get hidePassword => isEnglish ? 'Hide password' : '隐藏密码';
  String get showPassword => isEnglish ? 'Show password' : '显示密码';
  String get welcomeBack => isEnglish ? 'Welcome back' : '欢迎回来';
  String get createAccountTitle => isEnglish ? 'Create your account' : '创建你的账号';
  String get checkEmail => isEnglish ? 'Check your email' : '查收验证邮件';
  String get resetPassword => isEnglish ? 'Reset your password' : '重置密码';
  String get placesPreferencesInOne => isEnglish
      ? 'Your places and preferences, in one place.'
      : '登录后，管理你的常用地址与偏好。';
  String get saveFavouritesMakeNavio => isEnglish
      ? 'Save your favourites. Make NAVIO yours.'
      : '收藏常用地址，让 NAVIO 更懂你的出行。';
  String get enterVerificationCodeSent => isEnglish
      ? 'Enter the verification code sent to your email.'
      : '输入邮件中的验证码，完成账号注册。';
  String get enterEmailCodeChoose => isEnglish
      ? 'Enter your email code and choose a new password.'
      : '输入邮件验证码，并设置新密码。';
  String get resetCodeHint => isEnglish
      ? 'We’ll email you a code to reset your password.'
      : '我们将向你的邮箱发送密码重置验证码。';
  String get emailLabel => isEnglish ? 'Email' : '邮箱';
  String get emailCodeLabel => isEnglish ? 'Code from email' : '邮件验证码';
  String get newPasswordLabel => isEnglish ? 'New password' : '新密码';
  String get passwordLabel => isEnglish ? 'Password' : '密码';
  String get repeatPasswordLabel => isEnglish ? 'Repeat password' : '再次输入密码';
  String get atLeast6Characters => isEnglish
      ? 'At least 6 characters. A longer, unique password is safer.'
      : '至少 6 位，建议使用更长且不重复的密码。';
  String get forgotPassword => isEnglish ? 'Forgot password?' : '忘记密码？';
  String get signInAction => isEnglish ? 'Sign in' : '登录';
  String get createAccountAction => isEnglish ? 'Create account' : '创建账号';
  String get verifyEmail => isEnglish ? 'Verify email' : '验证邮箱';
  String get setNewPassword => isEnglish ? 'Set new password' : '设置新密码';
  String get sendRecoveryCode => isEnglish ? 'Send recovery code' : '发送重置验证码';
  String get orContinueWith => isEnglish ? 'or continue with' : '或通过以下方式继续';
  String get continueGoogle =>
      isEnglish ? 'Continue with Google' : '通过 Google 继续';
  String get continueApple => isEnglish ? 'Continue with Apple' : '通过 Apple 继续';
  String get alreadyHaveAccount =>
      isEnglish ? 'Already have an account?' : '已有账号？';
  String get newNavio => isEnglish ? 'New to NAVIO?' : '第一次使用 NAVIO？';
  String get registerAction => isEnglish ? 'Register' : '注册';
  String get backSignIn => isEnglish ? 'Back to sign in' : '返回登录';
  String get guestNavigationNeedsNo => isEnglish
      ? 'Guest navigation needs no account. When signed in, your saved places and preferences sync automatically; guest settings remain separate.'
      : '游客导航无需账号。登录后常用地址与偏好自动同步，游客资料独立保留。';
  String get personalProfile => isEnglish ? 'Personal profile' : '个人资料';
  String get navioAccount => isEnglish ? 'NAVIO Account' : 'NAVIO 账号';
  String get accountServiceNotConfigured => isEnglish
      ? 'Account service is not configured in this build. Maps and Bluetooth still work.'
      : '此版本尚未配置账号服务，地图与蓝牙仍可正常使用。';
  String get switchingAccountsCloudRestore => isEnglish
      ? 'Switching accounts and cloud restore are paused during navigation.'
      : '导航期间暂不切换账号或恢复云端资料。';
  String get accountHeader => isEnglish ? 'ACCOUNT' : '账号';
  String get signOut => isEnglish ? 'Sign out' : '退出登录';
  String get reauthorizeApple =>
      isEnglish ? 'Reauthorize Apple' : '重新验证 Apple 授权';
  String get deleteAccount => isEnglish ? 'Delete account' : '删除账号';
  String get deleteNavioAccount =>
      isEnglish ? 'Delete NAVIO account?' : '删除 NAVIO 账号？';
  String get permanentlyDeleteAccountIts => isEnglish
      ? 'Permanently delete your account and its cloud addresses/preferences. Type DELETE. Guest data and Bluetooth pairing are separate.'
      : '永久删除账号及其云端地址与偏好。输入 DELETE 确认。游客资料和蓝牙配对独立保留。';
  String get couldNotConnectPlease =>
      isEnglish ? 'Could not connect. Please try again.' : '连接失败，请重试。';
  String get connectionInterrupted =>
      isEnglish ? 'Connection interrupted' : '连接未完成';
  String get displayNowSavedOn =>
      isEnglish ? 'This display is now saved on your phone.' : '这块屏幕已保存到你的手机。';
  String get chooseScreenInFront =>
      isEnglish ? 'Choose the screen in front of you.' : '请选择你面前的那块屏幕。';
  String get bringDisplayNearIphone =>
      isEnglish ? 'Bring your display near this iPhone.' : '请将导航屏靠近手机。';
  String get tryAgain => isEnglish ? 'Try again' : '重试';
  String get navigationDiagnostics =>
      isEnglish ? 'Navigation diagnostics' : '导航诊断日志';
  String get noEventsRecorded => isEnglish ? 'No events recorded.' : '暂无记录。';
  String get copyLog => isEnglish ? 'Copy log' : '复制日志';
  String get clearLog => isEnglish ? 'Clear log' : '清空日志';
  String get closeAction => isEnglish ? 'Close' : '关闭';
  String get notConnected => isEnglish ? 'Not connected' : '未连接';
  String get diagnosticsScope => isEnglish
      ? 'Last 200 events this session. No coordinates or uploads.'
      : '本次运行最近 200 条，不含坐标，不上传。';
  String get voiceUnavailableOnDevice =>
      isEnglish ? 'Voice is unavailable on this device.' : '此设备暂不支持语音播报。';
  String get mapSettings => isEnglish ? 'Map settings' : '地图设置';
  String get nextStop => isEnglish ? "Next stop" : "下一途经点";
  String get allStopsVisitedContinuing => isEnglish
      ? 'All stops visited · continuing to destination'
      : '途经点已全部经过 · 继续前往终点';
  String get routePreferences => isEnglish ? 'Route preferences' : '路线偏好';
  String get mapAppearanceHeader => isEnglish ? 'MAP APPEARANCE' : '地图外观';
  String get mapStyleStandard => isEnglish ? 'Standard' : '标准';
  String get clearStreetsLandmarks =>
      isEnglish ? 'Clear streets and landmarks' : '清晰显示道路与地标';
  String get mapStyleStandardDark => isEnglish ? 'Standard · Dark' : '标准 · 深色';
  String get calmerMapNightRiding =>
      isEnglish ? 'A calmer map for night riding' : '适合夜间骑行的深色地图';
  String get mapStyleHybrid => isEnglish ? 'Hybrid' : '混合';
  String get aerialImageryRoadLabels =>
      isEnglish ? 'Aerial imagery with road labels' : '航拍影像与道路标注';
  String get mapStyleSatellite => isEnglish ? 'Satellite' : '卫星';
  String get aerialImageryWithoutLabels =>
      isEnglish ? 'Aerial imagery without labels' : '不显示道路标注的航拍影像';
  String get savedPlacesHeader => isEnglish ? 'SAVED PLACES' : '常用地址';
  String get couldNotResolveLocation => isEnglish
      ? 'Could not resolve this location link. Check the link or search by name/address. Only supported HTTPS map links are accepted.'
      : '无法解析此位置链接。请检查链接，或改用名称、地址搜索；仅支持指定地图域名的 HTTPS 链接。';
  String get confirmDestination => isEnglish ? 'Confirm destination' : '确认目的地';
  String get mapViewCentreNot => isEnglish
      ? 'This is the map view centre, not a verified place. Check the pin on the map before navigating.'
      : '这是地图视角中心，不是已验证的地点。请在地图上检查位置后再开始导航。';
  String get checkDestinationOnMap => isEnglish
      ? 'Check this destination on the map before starting navigation.'
      : '请在地图上确认此目的地后再开始导航。';
  String get showOnMap => isEnglish ? 'Show on map' : '在地图上查看';
  String get pasteLocationLink => isEnglish ? 'Paste location link' : '粘贴位置链接';
  String get addAction => isEnglish ? 'Add' : '添加';
  String get editName => isEnglish ? 'Edit name' : '修改名字';
  String get loading => isEnglish ? 'Loading…' : '读取中…';
  String get tapRetry => isEnglish ? 'Tap to retry' : '点击重试';
  String get nicknameLabel => isEnglish ? 'Nickname' : '昵称';
  String get doneAction => isEnglish ? 'Done' : '完成';
  String get nicknameHeader => isEnglish ? 'YOUR NICKNAME' : '你的昵称';
  String get nicknameHint => isEnglish
      ? '1–32 characters. Saved to your account when you finish editing. Nicknames do not need to be unique.'
      : '1–32 个字符，编辑完成后保存到账号。昵称无需唯一。';
  String get accountChangedGoBack => isEnglish
      ? 'Your account changed. Go back to your profile before editing.'
      : '账号已切换，请返回个人资料后重新编辑。';
  String get nicknameInvalid => isEnglish
      ? 'Use 1–32 characters, without line breaks or hidden control characters.'
      : '请输入 1–32 个字符，不含换行或隐藏控制字符。';
  String get nicknameChangedOnAnother => isEnglish
      ? 'Your nickname changed on another device. Load the latest name before editing again.'
      : '昵称已在其他设备修改，请读取最新昵称后重新编辑。';
  String get pleaseSignInAgain =>
      isEnglish ? 'Please sign in again before saving.' : '请重新登录后保存。';
  String get couldNotSaveDraft => isEnglish
      ? 'Could not save. Your draft is still here; check your connection and try Done again.'
      : '未能保存，输入内容仍保留。请检查网络后重试。';
  String get loadLatestName => isEnglish ? 'Load latest name' : '读取最新昵称';
  String get couldNotSavePlease =>
      isEnglish ? 'Could not save. Please try again.' : '保存失败，请重试。';
  String get backAction => isEnglish ? 'Back' : '返回';
  String get aboutAvoidance => isEnglish ? 'About avoidance' : '避让说明';
  String get savedAutomaticallyOnPhone => isEnglish
      ? 'Saved automatically on this phone. Highways, tolls and ferries are preferences, not guaranteed exclusions. Tunnels exclude mapped tunnel sections except at the start/end; map data may be incomplete. Change preferences before navigation. Saving clears the old route preview.'
      : '自动保存在本机。高速、收费路和轮渡为尽量避开，并非保证排除。隧道会排除地图已标注路段（起终点所在路段除外），地图可能不完整。请在导航前修改，保存后清除旧路线预览。';
  String get okAction => isEnglish ? 'OK' : '知道了';
  String get routeOptionsHeader => isEnglish ? 'ROUTE OPTIONS' : '路线选项';
  String get savedAutomaticallyAppliesNext => isEnglish
      ? 'Saved automatically. Applies to your next route.'
      : '自动保存，并应用于下一次路线规划。';
  String get preferAvoidingHighways =>
      isEnglish ? 'Prefer avoiding highways' : '尽量避开高速';
  String get preferAvoidingTolls =>
      isEnglish ? 'Prefer avoiding tolls' : '尽量避开收费路';
  String get preferAvoidingFerries =>
      isEnglish ? 'Prefer avoiding ferries' : '尽量避开轮渡';
  String get avoidTunnels => isEnglish ? 'Avoid tunnels' : '避开隧道';
  String get changePreferencesBeforeStarting => isEnglish
      ? 'Change preferences before starting navigation.'
      : '请在开始导航前修改偏好。';
  String get chooseDifferentPlaceStop => isEnglish
      ? 'Choose a different place; this stop is already in the trip.'
      : '此地点已在行程中，请选择其他途经点。';
  String get tripStops => isEnglish ? 'Trip stops' : '途经点';
  String get placesVisitedInOrder => isEnglish
      ? 'Places are visited in the order below. Navigation continues automatically after each stop.'
      : '按下方顺序经过各地点，经过途经点后自动继续导航。';
  String get currentLocation => isEnglish ? 'Current location' : '当前位置';
  String get moveUp => isEnglish ? 'Move up' : '上移';
  String get moveDown => isEnglish ? 'Move down' : '下移';
  String get removeStop => isEnglish ? 'Remove stop' : '删除途经点';
  String get finalDestination => isEnglish ? 'Final destination' : '最终目的地';
  String get alternativeRoutesUnavailableTrips => isEnglish
      ? 'Alternative routes are unavailable for trips with stops.'
      : '含途经点的行程暂不提供备选路线。';
  String get signInNavio => isEnglish ? 'Sign in to NAVIO' : '登录 NAVIO 账号';
  String get accountProfile => isEnglish ? 'Account and profile' : '账号与个人资料';
  String get profileLabel => isEnglish ? 'Profile' : '个人资料';
  String get followSystem => isEnglish ? 'Follow system' : '跟随系统';
  String get languageLabel => isEnglish ? 'Language' : '语言';
  String get photoVisibleSignedIn => isEnglish
      ? 'Your photo is visible to signed-in riders only while you share your location. Only a small cropped copy is saved, not the original photo.'
      : '仅在共享位置时向已登录骑友展示头像。只保存裁剪后的小图，不上传原照片。';
  String get changePhoto => isEnglish ? 'Change photo' : '更换头像';
  String get choosePhoto => isEnglish ? 'Choose photo' : '设置头像';
  String get removePhoto => isEnglish ? 'Remove photo' : '移除头像';
  String get useProfilePhoto =>
      isEnglish ? 'Use this profile photo?' : '使用这个头像？';
  String get visibleRidersWhenShare => isEnglish
      ? 'Visible to riders when you share your location.'
      : '共享位置时，骑友可以看到此头像。';
  String get usePhoto => isEnglish ? 'Use photo' : '使用头像';
  String get removeProfilePhoto =>
      isEnglish ? 'Remove profile photo?' : '移除头像？';
  String get accountRiderMarkerWill => isEnglish
      ? 'Your account and rider marker will use the default avatar.'
      : '账号与骑友地图将恢复默认头像。';
  String get removeAction => isEnglish ? 'Remove' : '移除';
  String get editProfilePhoto => isEnglish ? 'Edit profile photo' : '编辑个人头像';
  String get photoPermissionDenied => isEnglish
      ? 'Photo access was denied. Allow access in Settings, then try again.'
      : '未获得照片访问权限，请在系统设置中允许后重试。';
  String get photoInvalid => isEnglish
      ? 'This photo could not be processed. Choose a different image.'
      : '这张照片无法处理，请选择另一张图片。';
  String get photoUnavailable => isEnglish
      ? 'Photo could not be loaded or saved. Check your connection and retry.'
      : '头像读取或保存失败，请检查网络后重试。';
  String get reloadPhoto => isEnglish ? 'Reload photo' : '重新读取头像';
  String get sydneyRiders => isEnglish ? 'Sydney riders' : '悉尼骑友';
  String get onlyRidersWhoChoose => isEnglish
      ? 'Only riders who choose to share appear. Viewing does not share your location.'
      : '只显示自愿共享的骑友。查看地图不会自动公开你的位置。';
  String get signInUnderMy => isEnglish
      ? 'Sign in under My devices to use this feature.'
      : '请先在 My devices 登录账号。';
  String get showRiders => isEnglish ? 'Show riders' : '显示骑友';
  String get ridersRefreshHint =>
      isEnglish ? 'Refreshes about every 5 seconds' : '约每 5 秒刷新';
  String get shareMyPositionDuring =>
      isEnglish ? 'Share my position during navigation' : '导航期间共享我的位置';
  String get publicSignedInNavio => isEnglish
      ? 'Public to signed-in NAVIO users · approximate 100 m grid'
      : '所有已登录 NAVIO 用户可见 · 约百米网格位置';
  String get shareLocationPublicly =>
      isEnglish ? 'Share your location publicly?' : '公开共享你的位置？';
  String get otherSignedInUsers => isEnglish
      ? 'Other signed-in users can see your profile photo and follow your approximate live location while you navigate in the Sydney area. No route or destination is shared. Arrival, ending navigation or turning this off withdraws it; network loss may leave a marker visible for up to about 30 seconds. People can copy visible photos or positions. This is off again when the app restarts.'
      : '悉尼区域内导航时，其他已登录用户可看到你的个人头像并持续查看近似位置；不共享路线和目的地。到达、结束导航或关闭开关后撤下；网络异常时标记可能保留约 30 秒。可见的头像和位置可能被他人截取保存。重启 App 后默认关闭。';
  String get agreeShare => isEnglish ? 'Agree and share' : '同意并共享';
  String get sharingWhenAccurateFresh => isEnglish
      ? 'Sharing when an accurate, fresh location is available.'
      : '获取到新鲜、准确定位时共享。';
  String get notSharingNowWaiting => isEnglish
      ? 'Not sharing now; waiting for active navigation.'
      : '当前未共享，等待开始导航。';
  String get showingUp500Riders => isEnglish
      ? 'Showing up to 500 riders. More riders are online.'
      : '当前最多显示 500 位骑友，还有更多骑友在线。';
  String get riderServiceUnavailableNavigation => isEnglish
      ? 'Rider service unavailable. Navigation is unaffected.'
      : '骑友服务暂不可用，不影响导航。';
  String get notSet => isEnglish ? 'Not set' : '未设置';
  String get editAction => isEnglish ? 'Edit' : '修改';
  String get couldNotLoadOr => isEnglish
      ? 'Could not load or save address. Please try again.'
      : '地址读取或保存失败，请重试。';
  String get upDate => isEnglish ? 'Up to date' : '已同步';
  String get syncing => isEnglish ? 'Syncing…' : '正在同步…';
  String get waitingSyncTapRetry =>
      isEnglish ? 'Waiting to sync · tap to retry' : '等待同步 · 点击重试';
  String get settingsNeedReview =>
      isEnglish ? 'Settings need review' : '设置冲突，请确认';
  String get savedLocallySyncWhen =>
      isEnglish ? 'Saved locally · sync when idle' : '已保存在本机，空闲时同步';
  String get changesSavedOnPhone =>
      isEnglish ? 'Changes saved on this phone' : '修改已保存在本机';
  String get syncUnavailableInBuild =>
      isEnglish ? 'Sync unavailable in this build' : '此版本暂不可同步设置';
  String get settingsSyncFooter => isEnglish
      ? 'Saved places, map/route preferences, voice and language sync automatically. Bluetooth keys and location history stay off the cloud. Guest settings remain separate.'
      : '常用地址、地图与路线偏好、播报和语言自动同步。不上传蓝牙密钥或定位轨迹，游客资料独立保留。';
  String get automaticSync => isEnglish ? 'Automatic sync' : '自动同步';
  String get reviewConflictingSettings =>
      isEnglish ? 'Review conflicting settings' : '确认冲突设置';
  String get someValuesChangedBoth => isEnglish
      ? 'Some values changed both here and on another device. Choose which conflicting values to keep. Other changes will still be merged.'
      : '部分设置在本机和其他设备都被修改。请选择冲突项保留哪份；其他修改仍会合并。';
  String get keepPhoneSConflicting =>
      isEnglish ? 'Keep this phone’s conflicting values' : '冲突项保留本机版本';
  String get useCloudValuesConflicts =>
      isEnglish ? 'Use cloud values for conflicts' : '冲突项使用云端版本';
  List<String> get savedPlaceLabels =>
      isEnglish ? const ['Home', 'Work', 'School'] : const ['家', '公司', '学校'];
  String addStop(int count, int max) =>
      isEnglish ? 'Add stop ($count/$max)' : '添加途经点（$count/$max）';
  String guidanceVoiceToggle(bool enabled) => isEnglish
      ? (enabled ? 'Turn off guidance voice' : 'Turn on guidance voice')
      : (enabled ? '关闭导航播报' : '开启导航播报');
  String editStops(int count) => isEnglish
      ? (count == 0 ? 'Add stops' : 'Edit stops ($count)')
      : (count == 0 ? '添加途经点' : '编辑途经点（$count）');
}
