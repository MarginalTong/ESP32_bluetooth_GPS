import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../l10n/app_text.dart';
import 'home_page.dart';
import 'devices_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selected = 0;
  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return Scaffold(
      body: IndexedStack(
          index: _selected, children: const [HomePage(), DevicesPage()]),
      bottomNavigationBar: CupertinoTabBar(
        backgroundColor: const Color(0xf5fafafa),
        activeColor: const Color(0xff007aff),
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
