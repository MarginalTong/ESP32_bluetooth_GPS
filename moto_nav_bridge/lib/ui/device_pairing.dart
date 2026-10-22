import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../l10n/app_text.dart';
import '../services/ble_service.dart';

/// One bottom sheet owns selection, physical confirmation and success. The
/// rider never types or sees a code, but must choose the intended display.
Future<void> connectDisplay(BuildContext context, BleService ble) =>
    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x72000000),
      builder: (_) => _PairingSheet(ble: ble),
    );

class _PairingSheet extends StatefulWidget {
  const _PairingSheet({required this.ble});

  final BleService ble;

  @override
  State<_PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<_PairingSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..repeat(reverse: true);
  Completer<BluetoothDevice?>? _choice;
  List<ScanResult> _candidates = const [];
  String? _selectedName;
  String? _error;
  bool _success = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  @override
  void dispose() {
    if (_choice?.isCompleted == false) _choice!.complete(null);
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!mounted) return;
    setState(() {
      _candidates = const [];
      _selectedName = null;
      _error = null;
      _success = false;
    });
    try {
      await widget.ble.connect(
        timeout: const Duration(seconds: 10),
        chooseDevice: (results) async {
          if (!mounted || results.isEmpty) return null;
          final choice = Completer<BluetoothDevice?>();
          setState(() {
            _candidates = results;
            _choice = choice;
          });
          return choice.future;
        },
      );
      if (!mounted) return;
      if (widget.ble.state == BleConnectionState.connected) {
        setState(() => _success = true);
        await Future<void>.delayed(const Duration(milliseconds: 950));
        if (mounted) Navigator.of(context).pop();
      } else {
        setState(() => _error = widget.ble.lastError ??
            (AppText.of(context).isEnglish
                ? 'Could not connect. Please try again.'
                : '连接失败，请重试。'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = AppText.of(context).deviceActionFailed);
      }
    }
  }

  void _select(ScanResult result) {
    final choice = _choice;
    if (choice == null || choice.isCompleted) return;
    setState(() {
      _selectedName = _displayName(result);
      _candidates = const [];
    });
    choice.complete(result.device);
  }

  void _close() {
    if (_choice?.isCompleted == false) _choice!.complete(null);
    if (widget.ble.state != BleConnectionState.connected) {
      unawaited(widget.ble.disconnect());
    }
    Navigator.of(context).pop();
  }

  String _displayName(ScanResult result) {
    final advertised = result.advertisementData.advName;
    return advertised.isNotEmpty ? advertised : result.device.platformName;
  }

  @override
  Widget build(BuildContext context) {
    final text = AppText.of(context);
    return PopScope(
      canPop: false,
      child: AnimatedBuilder(
        animation: widget.ble,
        builder: (context, _) {
          final waiting = widget.ble.state == BleConnectionState.awaitingBoot;
          final choosing = _candidates.isNotEmpty;
          final title = _success
              ? text.deviceConnected
              : waiting
                  ? text.pressBoot
                  : choosing
                      ? text.selectDisplay
                      : _error != null
                          ? (text.isEnglish
                              ? 'Connection interrupted'
                              : '连接未完成')
                          : widget.ble.state == BleConnectionState.scanning
                              ? text.searchingDevice
                              : text.connecting;
          final subtitle = _success
              ? (text.isEnglish
                  ? 'This display is now saved on your phone.'
                  : '这块屏幕已保存到你的手机。')
              : waiting
                  ? text.bootHint
                  : choosing
                      ? (text.isEnglish
                          ? 'Choose the screen in front of you.'
                          : '请选择你面前的那块屏幕。')
                      : _error ??
                          (text.isEnglish
                              ? 'Bring your display near this iPhone.'
                              : '请将导航屏靠近手机。');
          return Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
            decoration: BoxDecoration(
              color: const Color(0xfff9fafc),
              borderRadius: BorderRadius.circular(34),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x29000000),
                    blurRadius: 34,
                    offset: Offset(0, -10))
              ],
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xffd7dce4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: _close,
                      child: const Icon(CupertinoIcons.xmark_circle_fill,
                          color: Color(0xffa8adb7), size: 27),
                    ),
                  ),
                  _DisplayAnimation(pulse: _pulse, success: _success),
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    child: Text(title,
                        key: ValueKey(title),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.6,
                            color: Color(0xff1c2230))),
                  ),
                  const SizedBox(height: 6),
                  Text(subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          color: Color(0xff626a78))),
                  if (_selectedName != null) ...[
                    const SizedBox(height: 8),
                    Text(_selectedName!,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xff4465a4))),
                  ],
                  const SizedBox(height: 22),
                  if (choosing)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _candidates.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final result = _candidates[index];
                          return CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            onPressed: () => _select(result),
                            child: Row(children: [
                              const Icon(CupertinoIcons.device_phone_portrait,
                                  color: Color(0xff2776d9)),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_displayName(result),
                                        style: const TextStyle(
                                            color: Color(0xff1c2230),
                                            fontWeight: FontWeight.w600)),
                                    Text(result.device.remoteId.str,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xff8c94a1))),
                                  ],
                                ),
                              ),
                              const Icon(CupertinoIcons.chevron_right,
                                  size: 16, color: Color(0xff8c94a1)),
                            ]),
                          );
                        },
                      ),
                    )
                  else if (_error != null)
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoButton.filled(
                        onPressed: _connect,
                        child: Text(text.isEnglish ? 'Try again' : '重试'),
                      ),
                    )
                  else if (!_success)
                    const CupertinoActivityIndicator(radius: 13),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DisplayAnimation extends StatelessWidget {
  const _DisplayAnimation({required this.pulse, required this.success});

  final Animation<double> pulse;
  final bool success;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 190,
        height: 150,
        child: AnimatedBuilder(
          animation: pulse,
          builder: (context, _) => Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: 0.88 + pulse.value * 0.25,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      const Color(0xff70aeff)
                          .withValues(alpha: 0.25 - pulse.value * 0.13),
                      const Color(0xff70aeff).withValues(alpha: 0),
                    ]),
                  ),
                ),
              ),
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xffedf5ff),
                  border: Border.all(color: const Color(0xffd5e8ff), width: 1),
                ),
              ),
              Container(
                width: 87,
                height: 87,
                decoration: BoxDecoration(
                    color: const Color(0xff1e2735),
                    borderRadius: BorderRadius.circular(25),
                    border:
                        Border.all(color: const Color(0xff647285), width: 4),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x39092c58),
                          blurRadius: 17,
                          offset: Offset(0, 9))
                    ]),
                child: Icon(
                    success
                        ? CupertinoIcons.check_mark
                        : CupertinoIcons.location_north_fill,
                    color: Colors.white,
                    size: 34),
              ),
            ],
          ),
        ),
      );
}
