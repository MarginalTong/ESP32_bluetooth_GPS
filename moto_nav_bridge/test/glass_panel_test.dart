import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moto_nav_bridge/ui/widgets/glass_panel.dart';

void main() {
  testWidgets('glass controls remain tappable and support high contrast',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(highContrast: true),
      child: Scaffold(
          body: GlassPanel(
              child: FilledButton(
        onPressed: () => taps++,
        child: const Text('End navigation'),
      ))),
    )));
    await tester.tap(find.text('End navigation'));
    expect(taps, 1);
    expect(tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass material preview on a colored backdrop', (tester) async {
    tester.view.physicalSize = const Size(390, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: RepaintBoundary(
      key: const ValueKey('preview'),
      child: Scaffold(
          body: Stack(children: [
        Positioned.fill(
            child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Color(0xffd6ecc5),
                    Color(0xfff5efe8),
                    Color(0xff96cbe5)
                  ], begin: Alignment.topLeft, end: Alignment.bottomRight),
                ),
                child: CustomPaint(painter: _Streets()))),
        Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              const SizedBox(height: 30),
              const GlassPanel(
                  padding: EdgeInsets.all(22),
                  child: Row(children: [
                    Icon(Icons.bluetooth, color: Colors.blue),
                    SizedBox(width: 18),
                    Text('Ready to go',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w600)),
                  ])),
              const Spacer(),
              GlassPanel(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Turn right ahead',
                          style: TextStyle(fontSize: 18)),
                      const SizedBox(height: 12),
                      const Text('↱ 105 m',
                          style: TextStyle(
                              fontSize: 44, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 22),
                      FilledButton(
                          onPressed: () {},
                          child: const Text('End navigation')),
                    ],
                  )),
              const SizedBox(height: 20),
            ])),
      ])),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('GLASS_PREVIEW')) {
      await expectLater(find.byKey(const ValueKey('preview')),
          matchesGoldenFile('goldens/glass_preview.png'));
    }
  });
}

class _Streets extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 12;
    for (var x = -400.0; x < 700; x += 65) {
      canvas.drawLine(Offset(x, 0), Offset(x + 300, size.height), paint);
    }
    for (var y = 0.0; y < 700; y += 85) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - 180), paint);
    }
  }

  @override
  bool shouldRepaint(_Streets oldDelegate) => false;
}
