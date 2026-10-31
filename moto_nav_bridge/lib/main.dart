import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'controllers/navigation_controller.dart';
import 'config/app_brand.dart';
import 'config/account_config.dart';
import 'controllers/account_controller.dart';
import 'controllers/avatar_controller.dart';
import 'controllers/profile_controller.dart';
import 'controllers/settings_sync_controller.dart';
import 'services/avatar_backend.dart';
import 'services/profile_backend.dart';
import 'controllers/rider_map_controller.dart';
import 'services/supabase_rider_backend.dart';
import 'services/local_account_data.dart';
import 'services/supabase_account_backend.dart';
import 'services/ble_service.dart';
import 'ui/app_shell.dart';
import 'ui/navio_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  SupabaseAccountBackend backend;
  try {
    backend = await SupabaseAccountBackend.initialize(
      AccountConfig.environment,
    );
  } catch (_) {
    backend = SupabaseAccountBackend(
      null,
    ); // A cloud outage must not stop navigation.
  }
  final account = AccountController(backend, LocalAccountData(preferences));
  try {
    await account.initialize();
  } catch (_) {
    account.error = 'local';
  }
  final riders = RiderMapController(SupabaseRiderBackend(backend.client));
  backend.beforeSignOut = riders.stopBeforeSignOut;
  final avatars = AvatarController(
    account,
    SupabaseAvatarBackend(backend.client),
  );
  final profile = ProfileController(
    account,
    SupabaseProfileBackend(backend.client),
    preferences,
  );
  final settingsSync = SettingsSyncController(account);
  runApp(
    NavioApp(
      preferences: preferences,
      account: account,
      riders: riders,
      avatars: avatars,
      profile: profile,
      settingsSync: settingsSync,
    ),
  );
}

class NavioApp extends StatelessWidget {
  const NavioApp({
    super.key,
    this.preferences,
    this.account,
    this.riders,
    this.avatars,
    this.profile,
    this.settingsSync,
  });
  final SharedPreferences? preferences;
  final AccountController? account;
  final RiderMapController? riders;
  final AvatarController? avatars;
  final ProfileController? profile;
  final SettingsSyncController? settingsSync;

  NavigationController _navigation(BleService ble) {
    final nav = NavigationController(ble: ble, preferences: preferences);
    account?.bindNavigation(nav);
    riders?.bindNavigation(nav);
    return nav;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        if (account != null)
          ChangeNotifierProvider<AccountController>(create: (_) => account!),
        if (avatars != null)
          ChangeNotifierProvider<AvatarController>(create: (_) => avatars!),
        if (profile != null)
          ChangeNotifierProvider<ProfileController>(create: (_) => profile!),
        if (settingsSync != null)
          ChangeNotifierProvider<SettingsSyncController>(
            create: (_) => settingsSync!,
          ),
        if (riders != null)
          ChangeNotifierProvider<RiderMapController>(create: (_) => riders!),
        ChangeNotifierProvider(create: (_) => BleService()),
        ChangeNotifierProxyProvider<BleService, NavigationController>(
          create: (ctx) => _navigation(ctx.read<BleService>()),
          update: (ctx, ble, previous) => previous ?? _navigation(ble),
        ),
      ],
      child: MaterialApp(
        title: AppBrand.name,
        theme: NavioTheme.light(),
        darkTheme: NavioTheme.dark(),
        debugShowCheckedModeBanner: false,
        home: const AppShell(),
      ),
    );
  }
}
