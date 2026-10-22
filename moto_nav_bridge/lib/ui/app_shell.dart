import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_text.dart';
import '../services/ble_service.dart';
import 'home_page.dart';
import 'devices_page.dart';
import 'map_settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selected = 0;
  String _mapStyle = 'standard';

  @override
  void initState() {
    super.initState();
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

  Future<void> _loadMapStyle() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getString(MapSettingsPage.styleKey);
    setState(() => _mapStyle = saved ?? 'standard');
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final darkBar = _mapStyle != 'standard';
    return Scaffold(
      body: IndexedStack(index: _selected, children: [
        HomePage(onMapStyleChanged: (style) {
          if (mounted && style != _mapStyle) setState(() => _mapStyle = style);
        }),
        const DevicesPage(),
      ]),
      bottomNavigationBar: CupertinoTabBar(
        backgroundColor:
            darkBar ? const Color(0xff121820) : const Color(0xf5fafafa),
        activeColor:
            darkBar ? const Color(0xff74b5ff) : const Color(0xff007aff),
        inactiveColor:
            darkBar ? const Color(0xff8996a8) : const Color(0xff8e8e93),
        currentIndex: _selected,
        onTap: (value) => setState(() => _selected = value),
        items: [
          BottomNavigationBarItem(
              icon: const Icon(CupertinoIcons.map),
              activeIcon: const Icon(CupertinoIcons.map_fill),
              label: text.mapTab),
          BottomNavigationBarItem(
              icon: const Icon(CupertinoIcons.device_phone_portrait),
              label: text.myDevices),
        ],
      ),
    );
  }
}
