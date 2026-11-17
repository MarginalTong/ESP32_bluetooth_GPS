import 'package:flutter/cupertino.dart';
import '../navio_feedback.dart';

class NavioTabIcon extends StatelessWidget {
  const NavioTabIcon({super.key, required this.icon, required this.selected});
  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: MediaQuery.disableAnimationsOf(context) ? 1 : (selected ? 1.07 : 1),
    duration: NavioMotion.duration(context, NavioMotion.stateChange),
    curve: Curves.easeOutCubic,
    child: Icon(icon),
  );
}
