import 'package:flutter/cupertino.dart';
import '../navio_theme.dart';

/// Native authentication action, using Google's official full-colour mark.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({super.key, required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? NavioColors.googleFillDark : NavioColors.googleFillLight,
        border: Border.all(
          color: dark
              ? NavioColors.googleBorderDark
              : NavioColors.googleBorderLight,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: CupertinoButton(
        onPressed: onPressed,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        borderRadius: BorderRadius.circular(14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/auth/google-g.png',
              width: 20,
              height: 20,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: dark
                      ? NavioColors.googleTextDark
                      : NavioColors.googleTextLight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
