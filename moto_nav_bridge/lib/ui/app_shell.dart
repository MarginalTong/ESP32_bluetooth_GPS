import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_text.dart';
import '../services/ble_service.dart';
import '../controllers/account_controller.dart';
import '../controllers/settings_sync_controller.dart';
import '../controllers/rider_map_controller.dart';
import 'home_page.dart';
import 'devices_page.dart';
import 'map_settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selected = 0;
  String _mapStyle = 'standard';
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMapStyle();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final ble = context.read<BleService>();
      try {
        await ble.refreshBinding();
        if (mounted &&
            ble.boundIdentity != null &&
            ble.state != BleConnectionState.connected) {
          await ble.connect(); // Only the saved display is eligible.
        }
      } catch (_) {
        // The device page retains the actionable binding/connection error.
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    context.read<SettingsSyncController?>()?.setForeground(_foreground);
    context.read<RiderMapController?>()?.setVisibility(
      foreground: _foreground,
      mapVisible: _selected == 0,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadMapStyle() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getString(MapSettingsPage.styleKey);
    setState(() => _mapStyle = saved ?? 'standard');
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final account = context.watch<AccountController?>();
    final darkBar =
        _mapStyle != 'standard' ||
        Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: IndexedStack(
        index: _selected,
        children: [
          HomePage(
            key: ValueKey(account?.localGeneration ?? 0),
            onMapStyleChanged: (style) {
              if (mounted && style != _mapStyle) {
                setState(() => _mapStyle = style);
              }
            },
          ),
          const DevicesPage(),
        ],
      ),
      bottomNavigationBar: CupertinoTabBar(
        backgroundColor: darkBar
            ? const Color(0xff121820)
            : const Color(0xf5fafafa),
        activeColor: darkBar
            ? const Color(0xff74b5ff)
            : const Color(0xff007aff),
        inactiveColor: darkBar
            ? const Color(0xff8996a8)
            : const Color(0xff8e8e93),
        currentIndex: _selected,
        onTap: (value) {
          if (value == 1) context.read<SettingsSyncController?>()?.request();
          setState(() => _selected = value);
          context.read<RiderMapController?>()?.setVisibility(
            foreground: _foreground,
            mapVisible: value == 0,
          );
        },
        items: [
          BottomNavigationBarItem(
            icon: const Icon(CupertinoIcons.map),
            activeIcon: const Icon(CupertinoIcons.map_fill),
            label: text.mapTab,
          ),
          BottomNavigationBarItem(
            icon: const Icon(CupertinoIcons.device_phone_portrait),
            label: text.myDevices,
          ),
        ],
      ),
    );
  }
}
