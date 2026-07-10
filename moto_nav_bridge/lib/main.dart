import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'controllers/navigation_controller.dart';
import 'services/ble_service.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const MotoNavBridgeApp());
}

class MotoNavBridgeApp extends StatelessWidget {
  const MotoNavBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleService()),
        ChangeNotifierProxyProvider<BleService, NavigationController>(
          create: (ctx) => NavigationController(ble: ctx.read<BleService>()),
          update: (ctx, ble, previous) =>
              previous ?? NavigationController(ble: ble),
        ),
      ],
      child: MaterialApp(
        title: 'Moto Nav Bridge',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xffff8a3d),
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xff0d0f12),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xff171a1f),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          useMaterial3: true,
        ),
        debugShowCheckedModeBanner: false,
        home: const HomePage(),
      ),
    );
  }
}
