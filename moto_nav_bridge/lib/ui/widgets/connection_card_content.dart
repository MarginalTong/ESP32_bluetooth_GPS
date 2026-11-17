import 'package:flutter/material.dart';
import '../navio_theme.dart';
import '../navio_feedback.dart';

/// Layout only. The parent owns cancellation, pairing and tap feedback.
class ConnectionCardContent extends StatelessWidget {
  const ConnectionCardContent({
    super.key,
    required this.connected,
    required this.busy,
    required this.stopping,
    required this.title,
    required this.message,
    required this.cancelLabel,
  });
  final bool connected, busy, stopping;
  final String title, message, cancelLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          ConnectionStatusDot(
            color: connected
                ? NavioColors.connected
                : busy
                ? colors.primary
                : colors.outline,
          ),
          const SizedBox(width: 12),
          Expanded(child: _labels(context)),
          _accessory(context),
        ],
      ),
    );
  }

  Widget _labels(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.start,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 1),
      Text(
        message,
        textAlign: TextAlign.start,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );

  Widget _accessory(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    if (!busy && !stopping) {
      return Icon(
        connected ? Icons.bluetooth_connected : Icons.bluetooth,
        color: color,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        if (!stopping) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: cancelLabel,
            child: Icon(Icons.close_rounded, color: color),
          ),
        ],
      ],
    );
  }
}

class ConnectionStatusDot extends StatelessWidget {
  const ConnectionStatusDot({super.key, required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: NavioMotion.duration(context, NavioMotion.stateChange),
    width: 10,
    height: 10,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}
