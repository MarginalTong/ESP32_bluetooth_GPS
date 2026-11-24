import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/navigation_controller.dart';
import '../../l10n/app_text.dart';
import '../navio_feedback.dart';
import 'glass_panel.dart';

/// Never silently restarts GPS or sends a cached instruction on application launch.
class SavedTripCard extends StatefulWidget {
  const SavedTripCard({super.key});
  @override
  State<SavedTripCard> createState() => _SavedTripCardState();
}

class _SavedTripCardState extends State<SavedTripCard> {
  bool _busy = false;

  Future<void> _resume() async {
    if (_busy) return;
    setState(() => _busy = true);
    await context.read<NavigationController>().resumeSavedNavigation();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationController>();
    if (!nav.hasSavedTrip) return const SizedBox.shrink();
    final text = AppText.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassPanel(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (nav.error != null) Text(nav.error!),
            FilledButton.icon(
              onPressed: NavioFeedback.action(context, _busy ? null : _resume),
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restore_rounded),
              label: Text(text.resumeNavigation),
            ),
            TextButton(
              onPressed: NavioFeedback.action(
                context,
                _busy ? null : nav.stopNavigation,
              ),
              child: Text(text.endNavigation),
            ),
          ],
        ),
      ),
    );
  }
}
