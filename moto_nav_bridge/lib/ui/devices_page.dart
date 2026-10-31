import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../controllers/navigation_controller.dart';
import 'package:provider/provider.dart';
import '../l10n/app_text.dart';
import '../config/app_brand.dart';
import 'navio_theme.dart';
import 'widgets/device_header.dart';
import '../services/ble_service.dart';
import 'device_pairing.dart';
import 'widgets/account_button.dart';

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
    final ble = context.read<BleService>();
    // Both logs share UTC ISO-8601 timestamps, so text order is time order.
    final log = ([
      ...nav.diagnostics.split('\n'),
      ...ble.diagnostics.split('\n'),
    ]..removeWhere((line) => line.isEmpty)
          ..sort())
        .join('\n');
    await showCupertinoModalPopup<void>(
        context: context,
        builder: (dialog) => CupertinoActionSheet(
              title: Text(en ? 'Navigation diagnostics' : '导航诊断日志'),
              message: SizedBox(
                  height: 220,
                  child: SingleChildScrollView(
                      child: SelectableText(
                          log.isEmpty
                              ? (en ? 'No events recorded.' : '暂无记录。')
                              : log,
                          style: const TextStyle(fontSize: 12)))),
              actions: [
                CupertinoActionSheetAction(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: log));
                      if (dialog.mounted) Navigator.pop(dialog);
                    },
                    child: Text(en ? 'Copy log' : '复制日志')),
                CupertinoActionSheetAction(
                    isDestructiveAction: true,
                    onPressed: () {
                      nav.clearDiagnostics();
                      ble.clearDiagnostics();
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
        ble.state == BleConnectionState.connecting ||
        ble.state == BleConnectionState.awaitingBoot;
    final connected = ble.state == BleConnectionState.connected;
    return NavioPage(
      child: CustomScrollView(slivers: [
        CupertinoSliverNavigationBar(
          largeTitle: Text(text.myDevices),
          trailing: const AccountButton(),
          backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(context),
          border: null,
        ),
        SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            sliver: SliverList.list(children: [
              DeviceHeader(
                name: ble.boundIdentity == null ? text.noBoundDevice : AppBrand.displayName(ble.boundIdentity!),
                status: connected ? text.deviceConnected : busy ? text.connecting : (text.isEnglish ? 'Not connected' : '未连接'),
                connected: connected,
                busy: busy,
                connectLabel: text.connectDevice,
                onConnect: busy ? null : () => _run(() => connectDisplay(context, ble)),
              ),
              if (_error == null &&
                  BleService.isWriteFailure(ble.lastError) &&
                  ble.lastErrorAt != null)
                _WriteFailureNotice(
                    error: ble.lastError!, at: ble.lastErrorAt!)
              else if (_error != null || ble.lastError != null)
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_error ?? ble.lastError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 28),
              DecoratedBox(
                  decoration: BoxDecoration(
                      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context),
                      borderRadius: BorderRadius.circular(12)),
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
                      color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context),
                      borderRadius: BorderRadius.circular(12)),
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
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: CupertinoColors.secondaryLabel.resolveFrom(context)))),
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
        ? CupertinoColors.tertiaryLabel.resolveFrom(context)
        : destructive
            ? const Color(0xffff3b30)
            : CupertinoColors.label.resolveFrom(context);
    return CupertinoButton(
      padding: const EdgeInsets.all(16),
      onPressed: onTap,
      child: Row(children: [
        SettingsIcon(icon, color: destructive ? CupertinoColors.systemRed : onTap == null ? CupertinoColors.systemGrey : CupertinoColors.systemBlue),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: TextStyle(
                  fontSize: 17, color: color, fontWeight: FontWeight.w400)),
          const SizedBox(height: 5),
          Text(subtitle,
              style: TextStyle(
                  fontSize: 13, height: 1.35, color: CupertinoColors.secondaryLabel.resolveFrom(context))),
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

/// A write failure with its age: red while recent, then grey, so an old
/// failure is not mistaken for a broken link. Cleared by the next good write.
class _WriteFailureNotice extends StatefulWidget {
  const _WriteFailureNotice({required this.error, required this.at});

  final String error;
  final DateTime at;

  @override
  State<_WriteFailureNotice> createState() => _WriteFailureNoticeState();
}

class _WriteFailureNoticeState extends State<_WriteFailureNotice> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final recent =
        BleService.isRecentWriteFailure(widget.error, widget.at, now);
    final colors = Theme.of(context).colorScheme;
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(AppText.of(context).writeFailedAgo(now.difference(widget.at)),
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: recent ? colors.error : colors.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(widget.error.substring(BleService.writeFailurePrefix.length).trim(),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
        ]));
  }
}
