import 'package:flutter/cupertino.dart';

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
        color: dark ? const Color(0xff131314) : const Color(0xffffffff),
        border: Border.all(
          color: dark ? const Color(0xff8e918f) : const Color(0xff747775),
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
                      ? const Color(0xffe3e3e3)
                      : const Color(0xff1f1f1f),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
