import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'controllers/navigation_controller.dart';
import 'config/app_brand.dart';
import 'config/account_config.dart';
import 'controllers/account_controller.dart';
import 'services/local_account_data.dart';
import 'services/supabase_account_backend.dart';
import 'services/ble_service.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  SupabaseAccountBackend backend;
  try {
    backend =
        await SupabaseAccountBackend.initialize(AccountConfig.environment);
  } catch (_) {
    backend = SupabaseAccountBackend(
        null); // A cloud outage must not stop navigation.
  }
  final account = AccountController(backend, LocalAccountData(preferences));
  try {
    await account.initialize();
  } catch (_) {
    account.error = 'local';
  }
  runApp(NavioApp(preferences: preferences, account: account));
}

class NavioApp extends StatelessWidget {
  const NavioApp({super.key, this.preferences, this.account});
  final SharedPreferences? preferences;
  final AccountController? account;

  NavigationController _navigation(BleService ble) {
    final nav = NavigationController(ble: ble, preferences: preferences);
    account?.bindNavigation(nav);
    return nav;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        if (account != null)
          ChangeNotifierProvider<AccountController>(create: (_) => account!),
        ChangeNotifierProvider(create: (_) => BleService()),
        ChangeNotifierProxyProvider<BleService, NavigationController>(
          create: (ctx) => _navigation(ctx.read<BleService>()),
          update: (ctx, ble, previous) => previous ?? _navigation(ble),
        ),
      ],
      child: MaterialApp(
        title: AppBrand.name,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff007aff),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xfff2f4f7),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xffe9eef4),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0x387bbfff),
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0x55ffffff)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          useMaterial3: true,
        ),
        debugShowCheckedModeBanner: false,
        home: const AppShell(),
      ),
    );
  }
}
