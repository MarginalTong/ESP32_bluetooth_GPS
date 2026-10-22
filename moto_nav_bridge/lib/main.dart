import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'controllers/navigation_controller.dart';
import 'services/ble_service.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  runApp(MotoNavBridgeApp(preferences: preferences));
}

class MotoNavBridgeApp extends StatelessWidget {
  const MotoNavBridgeApp({super.key, this.preferences});
  final SharedPreferences? preferences;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleService()),
        ChangeNotifierProxyProvider<BleService, NavigationController>(
          create: (ctx) => NavigationController(
              ble: ctx.read<BleService>(), preferences: preferences),
          update: (ctx, ble, previous) =>
              previous ??
              NavigationController(ble: ble, preferences: preferences),
        ),
      ],
      child: MaterialApp(
        title: 'Moto Nav Bridge',
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
