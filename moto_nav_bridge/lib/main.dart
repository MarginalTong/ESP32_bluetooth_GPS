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
          create: (ctx) =>
              NavigationController(ble: ctx.read<BleService>()),
          update: (ctx, ble, previous) =>
              previous ?? NavigationController(ble: ble),
        ),
      ],
      child: MaterialApp(
        title: 'Moto Nav Bridge',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.orange,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}
