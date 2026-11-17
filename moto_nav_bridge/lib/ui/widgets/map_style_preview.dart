import 'package:flutter/cupertino.dart';
import '../navio_theme.dart';

class MapStylePreview extends StatelessWidget {
  const MapStylePreview({super.key, required this.style});
  final String style;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(11),
    child: SizedBox.square(
      dimension: 46,
      child: CustomPaint(painter: _MapPreviewPainter(style)),
    ),
  );
}

class _MapPreviewPainter extends CustomPainter {
  const _MapPreviewPainter(this.style);
  final String style;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = style == 'standard_dark';
    final imagery = style == 'hybrid' || style == 'satellite';
    canvas.drawColor(
      dark
          ? NavioColors.previewDarkBase
          : imagery
          ? NavioColors.previewImageryBase
          : NavioColors.previewLightBase,
      BlendMode.src,
    );
    if (imagery) {
      canvas.drawCircle(
        const Offset(12, 14),
        18,
        Paint()..color = NavioColors.previewImageryField,
      );
      canvas.drawCircle(
        const Offset(41, 36),
        19,
        Paint()..color = NavioColors.previewImageryWater,
      );
    } else {
      canvas.drawCircle(
        const Offset(37, 7),
        17,
        Paint()
          ..color = dark
              ? NavioColors.previewDarkPark
              : NavioColors.previewLightPark,
      );
    }
    _roads(canvas);
  }

  void _roads(Canvas canvas) {
    final dark = style == 'standard_dark';
    if (style == 'satellite') return;
    final road = Paint()
      ..color = dark ? NavioColors.previewDarkRoad : CupertinoColors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(-4, 34), const Offset(50, 13), road);
    canvas.drawLine(const Offset(13, -4), const Offset(32, 50), road);
    final route = Paint()
      ..color = dark
          ? NavioColors.previewDarkRoute
          : NavioColors.previewLightRoute
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(4, 31), const Offset(42, 16), route);
  }

  @override
  bool shouldRepaint(covariant _MapPreviewPainter oldDelegate) =>
      oldDelegate.style != style;
}
