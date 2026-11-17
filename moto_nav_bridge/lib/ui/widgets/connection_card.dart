import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_brand.dart';
import '../../l10n/app_text.dart';
import 'glass_panel.dart';
import '../../services/ble_service.dart';
import '../device_pairing.dart';
import '../navio_theme.dart';
import '../navio_feedback.dart';

/// Display connection status over the map. Once the display has been
/// connected for a moment the card shrinks into a small pill in the top-left
/// corner; any problem, or a tap on the pill, brings the full card back.
class ConnectionCard extends StatefulWidget {
  const ConnectionCard({super.key, this.fullWidth, this.onCompactChanged});

  /// Width of the full card. Null fills the available width.
  final double? fullWidth;

  /// Reports when the card shrinks or grows, so the page can use the space.
  final ValueChanged<bool>? onCompactChanged;

  /// How long "Ready to go" stays readable before the card shrinks.
  static const settleDelay = Duration(milliseconds: 1200);

  /// How long a tapped pill stays expanded before shrinking again.
  static const expandedDuration = Duration(seconds: 5);
  static const resizeDuration = Duration(milliseconds: 350);

  @override
  State<ConnectionCard> createState() => _ConnectionCardState();
}

class _ConnectionCardState extends State<ConnectionCard> {
  Timer? _settleTimer, _expandTimer;
  bool _settled = false, _expanded = false;
  bool? _reportedCompact;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final connected =
        context.read<BleService>().state == BleConnectionState.connected;
    if (!connected) {
      _settleTimer?.cancel();
      _expandTimer?.cancel();
      _settleTimer = _expandTimer = null;
      _settled = _expanded = false;
    } else if (!_settled && _settleTimer == null) {
      _settleTimer = Timer(ConnectionCard.settleDelay, () {
        if (mounted) setState(() => _settled = true);
      });
    }
  }

  void _expand() {
    _expandTimer?.cancel();
    _expandTimer = Timer(ConnectionCard.expandedDuration, () {
      if (mounted) setState(() => _expanded = false);
    });
    setState(() => _expanded = true);
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _expandTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleService>();
    final status = _CardStatus.of(context, ble);
    final compact =
        status.connected && !status.hasIssue && _settled && !_expanded;
    if (compact != _reportedCompact) {
      _reportedCompact = compact;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onCompactChanged?.call(compact);
      });
    }
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : ConnectionCard.resizeDuration;
    return Align(
      alignment: Alignment.topLeft,
      child: GlassPanel(
        child: AnimatedSize(
          duration: duration,
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topLeft,
          child: AnimatedSwitcher(
            duration: duration ~/ 2,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, ?current],
            ),
            child: compact
                ? _CompactPill(key: const ValueKey('compact'), onTap: _expand)
                : _FullCard(
                    key: const ValueKey('full'),
                    width: widget.fullWidth,
                    status: status,
                  ),
          ),
        ),
      ),
    );
  }
}

/// What the card shows for the current link state.
class _CardStatus {
  const _CardStatus({
    required this.connected,
    required this.busy,
    required this.issue,
    required this.label,
  });

  factory _CardStatus.of(BuildContext context, BleService ble) {
    final text = AppText.of(context);
    final connected = ble.state == BleConnectionState.connected;
    final busy =
        ble.state == BleConnectionState.scanning ||
        ble.state == BleConnectionState.connecting ||
        ble.state == BleConnectionState.awaitingBoot;
    // An old write failure is history, not the link's current state.
    final writeFailed =
        !busy &&
        BleService.isRecentWriteFailure(
          ble.lastError,
          ble.lastErrorAt,
          DateTime.now(),
        );
    final hasError =
        !busy &&
        ble.lastError != null &&
        (writeFailed || !BleService.isWriteFailure(ble.lastError));
    final issue = !hasError
        ? null
        : writeFailed
        ? (text.displayUpdateInterrupted, text.reconnectDisplayHint)
        : _issue(text, ble.lastError!);
    return _CardStatus(
      connected: connected,
      busy: busy,
      issue: issue,
      label: _label(text, ble),
    );
  }

  final bool connected, busy;
  final (String, String)? issue;
  final String label;

  bool get hasIssue => issue != null;

  /// Short title and hint for a connection error; the raw text stays on the
  /// device page. A "not selected" scan is not a fault, so it has no issue.
  static (String, String)? _issue(AppText text, String error) {
    if (error.startsWith('No display selected')) return null;
    if (error.startsWith('Bluetooth is')) {
      return (text.bluetoothOff, text.bluetoothOffHint);
    }
    if (error.startsWith('Bound display is offline') ||
        error.startsWith('Connect failed')) {
      return (text.displayOffline, text.displayOfflineHint);
    }
    if (error.startsWith('BLE ')) {
      return (text.displayDisconnected, text.displayDisconnectedHint);
    }
    if (error.startsWith('Display security')) {
      return (text.pairDisplayAgain, text.pairDisplayAgainHint);
    }
    return (text.deviceConnectionIssue, text.deviceDetailsHint);
  }

  static String _label(AppText text, BleService ble) => switch (ble.state) {
    BleConnectionState.idle => text.displayNotConnected,
    BleConnectionState.scanning => text.searchingDevice,
    BleConnectionState.connecting => text.connecting,
    BleConnectionState.awaitingBoot =>
      ble.confirmsByPower ? text.pairingInProgress : text.pressBoot,
    BleConnectionState.connected => text.deviceConnected,
    BleConnectionState.disconnected => text.displayNotConnected,
  };
}

class _FullCard extends StatelessWidget {
  const _FullCard({super.key, required this.width, required this.status});

  final double? width;
  final _CardStatus status;

  @override
  Widget build(BuildContext context) {
    final ble = context.read<BleService>();
    final text = AppText.of(context);
    final colors = Theme.of(context).colorScheme;
    final issue = status.issue;
    return SizedBox(
      width: width ?? double.infinity,
      child: NavioPressEffect(
        enabled: !status.busy,
        child: InkWell(
          enableFeedback: false,
          borderRadius: BorderRadius.circular(18),
          onTap: NavioFeedback.action(
            context,
            status.busy
                ? null
                : () => status.connected
                      ? ble.disconnect()
                      : connectDisplay(context, ble),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                _StatusDot(
                  color: status.connected
                      ? NavioColors.connected
                      : status.busy
                      ? colors.primary
                      : colors.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        issue != null
                            ? issue.$1
                            : status.connected
                            ? text.readyToGo
                            : status.busy
                            ? text.connectingDisplay
                            : text.tapToConnect,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.start,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        status.busy ? status.label : issue?.$2 ?? status.label,
                        textAlign: TextAlign.start,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (status.busy)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    status.connected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth,
                    color: colors.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The connected state, reduced to a dot and the product name.
class _CompactPill extends StatelessWidget {
  const _CompactPill({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: AppText.of(context).deviceConnected,
    excludeSemantics: true,
    child: NavioPressEffect(
      enabled: true,
      child: InkWell(
        enableFeedback: false,
        borderRadius: BorderRadius.circular(18),
        onTap: NavioFeedback.action(
          context,
          onTap,
          feedback: InteractionFeedback.selection,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _StatusDot(color: NavioColors.connected),
              const SizedBox(width: 8),
              Text(
                AppBrand.name,
                maxLines: 1,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: NavioMotion.duration(context, NavioMotion.stateChange),
    width: 10,
    height: 10,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}
