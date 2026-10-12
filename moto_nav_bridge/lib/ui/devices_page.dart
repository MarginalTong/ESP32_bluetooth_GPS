import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../controllers/navigation_controller.dart';
import 'package:provider/provider.dart';
import '../l10n/app_text.dart';
import '../services/ble_service.dart';
import 'device_pairing.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});
  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _working = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _run(() => context.read<BleService>().refreshBinding());
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) _error = AppText.of(context).deviceActionFailed;
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _forget(bool replace) async {
    final text = AppText.of(context);
    final ble = context.read<BleService>();
    final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialog) => CupertinoAlertDialog(
              title: Text(replace ? text.replaceDevice : text.forgetDevice),
              content: Text(replace ? text.replaceHint : text.forgetHint),
              actions: [
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: Text(text.cancelAction)),
                CupertinoDialogAction(
                    isDestructiveAction: !replace,
                    onPressed: () => Navigator.pop(dialog, true),
                    child: Text(text.confirmAction)),
              ],
            ));
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await ble.forgetDevice();
      if (replace && mounted) await connectDisplay(context, ble);
    });
  }

  Future<void> _showDiagnostics() async {
    final en = AppText.of(context).isEnglish;
    final nav = context.read<NavigationController>();
    await showCupertinoModalPopup<void>(
        context: context,
        builder: (dialog) => CupertinoActionSheet(
              title: Text(en ? 'Navigation diagnostics' : '导航诊断日志'),
              message: SizedBox(
                  height: 220,
                  child: SingleChildScrollView(
                      child: SelectableText(
                          nav.diagnostics.isEmpty
                              ? (en ? 'No events recorded.' : '暂无记录。')
                              : nav.diagnostics,
                          style: const TextStyle(fontSize: 12)))),
              actions: [
                CupertinoActionSheetAction(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: nav.diagnostics));
                      if (dialog.mounted) Navigator.pop(dialog);
                    },
                    child: Text(en ? 'Copy log' : '复制日志')),
                CupertinoActionSheetAction(
                    isDestructiveAction: true,
                    onPressed: () {
                      nav.clearDiagnostics();
                      Navigator.pop(dialog);
                    },
                    child: Text(en ? 'Clear log' : '清空日志')),
              ],
              cancelButton: CupertinoActionSheetAction(
                  onPressed: () => Navigator.pop(dialog),
                  child: Text(en ? 'Close' : '关闭')),
            ));
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    final ble = context.watch<BleService>();
    final busy = _working ||
        ble.state == BleConnectionState.scanning ||
        ble.state == BleConnectionState.connecting;
    final connected = ble.state == BleConnectionState.connected;
    return CupertinoPageScaffold(
      backgroundColor: const Color(0xfff2f2f7),
      child: CustomScrollView(slivers: [
        CupertinoSliverNavigationBar(
          largeTitle: Text(text.myDevices),
          backgroundColor: const Color(0xf5f2f2f7),
          border: null,
        ),
        SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            sliver: SliverList.list(children: [
              DecoratedBox(
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24)),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 28),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                              child: Container(
                            width: 112,
                            height: 76,
                            decoration: BoxDecoration(
                              color: const Color(0xff20242c),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: const Color(0xff424955), width: 5),
                              boxShadow: const [
                                BoxShadow(
                                    color: Color(0x18000000),
                                    blurRadius: 20,
                                    offset: Offset(0, 8))
                              ],
                            ),
                            child: const Icon(Icons.turn_right_rounded,
                                size: 46, color: Colors.white),
                          )),
                          const SizedBox(height: 24),
                          Text(
                              ble.boundIdentity == null
                                  ? text.noBoundDevice
                                  : 'NAV-${ble.boundIdentity}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xff1c1c1e),
                                  letterSpacing: -.4)),
                          const SizedBox(height: 8),
                          Text(
                              connected
                                  ? text.deviceConnected
                                  : busy
                                      ? text.connecting
                                      : text.connectDevice,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 15,
                                  color: connected
                                      ? const Color(0xff248a3d)
                                      : const Color(0xff636366))),
                          if (busy)
                            const Padding(
                                padding: EdgeInsets.only(top: 16),
                                child: CupertinoActivityIndicator()),
                          if (!connected)
                            Padding(
                                padding: const EdgeInsets.only(top: 20),
                                child: CupertinoButton.filled(
                                    onPressed: busy
                                        ? null
                                        : () => _run(
                                            () => connectDisplay(context, ble)),
                                    child: Text(text.connectDevice))),
                        ],
                      ))),
              if (_error != null || ble.lastError != null)
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error ?? ble.lastError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 28),
              DecoratedBox(
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18)),
                  child: Column(children: [
                    _DeviceAction(
                        icon: Icons.bluetooth_disabled,
                        title: text.disconnectDevice,
                        subtitle: text.disconnectHint,
                        onTap: !busy && connected
                            ? () => _run(ble.disconnect)
                            : null),
                    const Padding(
                        padding: EdgeInsets.only(left: 56),
                        child: Divider(
                            height: 1,
                            thickness: .5,
                            color: Color(0xffdcdce0))),
                    _DeviceAction(
                        icon: Icons.swap_horiz_rounded,
                        title: text.replaceDevice,
                        subtitle: text.replaceHint,
                        onTap: !busy ? () => _forget(true) : null),
                  ])),
              const SizedBox(height: 20),
              DecoratedBox(
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18)),
                  child: _DeviceAction(
                      icon: Icons.link_off_rounded,
                      title: text.forgetDevice,
                      subtitle: text.forgetHint,
                      destructive: true,
                      onTap: !busy && ble.boundIdentity != null
                          ? () => _forget(false)
                          : null)),
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(text.bindingScope,
                      style: const TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: Color(0xff636366)))),
              const SizedBox(height: 20),
              _DeviceAction(
                  icon: Icons.receipt_long_outlined,
                  title: text.isEnglish ? 'Navigation diagnostics' : '导航诊断日志',
                  subtitle: text.isEnglish
                      ? 'Last 200 events this session. No coordinates or uploads.'
                      : '本次运行最近 200 条，不含坐标，不上传。',
                  onTap: _showDiagnostics),
            ])),
      ]),
    );
  }
}

class _DeviceAction extends StatelessWidget {
  const _DeviceAction(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap,
      this.destructive = false});
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? const Color(0xff8e8e93)
        : destructive
            ? const Color(0xffff3b30)
            : const Color(0xff007aff);
    return CupertinoButton(
      padding: const EdgeInsets.all(16),
      onPressed: onTap,
      child: Row(children: [
        Icon(icon, size: 23, color: color),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(
                  fontSize: 17, color: color, fontWeight: FontWeight.w500)),
          const SizedBox(height: 5),
          Text(subtitle,
              style: const TextStyle(
                  fontSize: 13, height: 1.35, color: Color(0xff636366))),
        ])),
        if (!destructive) ...[
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right_rounded,
              size: 20, color: Color(0xffc7c7cc)),
        ],
      ]),
    );
  }
}
