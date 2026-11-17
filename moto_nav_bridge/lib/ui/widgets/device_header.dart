import 'package:flutter/cupertino.dart';
import 'device_illustration.dart';
import '../navio_feedback.dart';

/// A product silhouette rather than another nested settings card.
class DeviceHeader extends StatelessWidget {
  const DeviceHeader({
    super.key,
    required this.name,
    required this.status,
    required this.connected,
    required this.busy,
    required this.connectLabel,
    this.onConnect,
  });
  final String name, status, connectLabel;
  final bool connected, busy;
  final VoidCallback? onConnect;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
    child: Column(
      children: [
        DeviceIllustration(connected: connected),
        const SizedBox(height: 24),
        Text(
          name,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -.5,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 6),
        _status(context),
        if (!connected) ...[
          const SizedBox(height: 22),
          _connectButton(context),
        ],
      ],
    ),
  );

  Widget _status(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      if (busy) ...[
        const CupertinoActivityIndicator(radius: 7),
        const SizedBox(width: 8),
      ],
      if (connected) ...[
        const Icon(
          CupertinoIcons.checkmark_circle_fill,
          size: 14,
          color: CupertinoColors.systemGreen,
        ),
        const SizedBox(width: 5),
      ],
      Flexible(
        child: Text(
          status,
          style: TextStyle(
            fontSize: 15,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      ),
    ],
  );

  Widget _connectButton(BuildContext context) => NavioPressEffect(
    enabled: !busy && onConnect != null,
    child: SizedBox(
      width: double.infinity,
      child: CupertinoButton.filled(
        onPressed: NavioFeedback.action(context, busy ? null : onConnect),
        borderRadius: BorderRadius.circular(14),
        child: Text(
          busy ? status : connectLabel,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}
