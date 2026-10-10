import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/main.dart';
import 'package:serial_spectrogram/signal_processor.dart';

// Draws the plots so they can be looked at. Run `flutter test --update-goldens` to regenerate
// the images in test/goldens/, then open them. (Text shows as blocks in tests.)
void main() {
  Future<void> drawPanels(WidgetTester tester, SignalProcessor processor, String name) async {
    await tester.binding.setSurfaceSize(const Size(900, 500));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.white,
          body: RepaintBoundary(
            key: const Key('plot'),
            child: PlotPanels(processor: processor, redraw: ValueNotifier(0)),
          ),
        ),
      ));
      await Future.delayed(const Duration(milliseconds: 200)); // let the spectrogram images decode
    });
    await tester.pump();
    await expectLater(find.byKey(const Key('plot')), matchesGoldenFile('goldens/$name.png'));
  }

  testWidgets('plots of the sample capture', (tester) async {
    final processor = SignalProcessor(warmup: 0); // the sample is shorter than the normal warm-up
    for (final line in File('sample_data.txt').readAsLinesSync()) {
      processor.addLine(line);
    }
    await drawPanels(tester, processor, 'sample');
  });

  testWidgets('plots of a made-up signal: rising tone, steady 20 Hz tone, noise', (tester) async {
    final processor = SignalProcessor();
    final rng = math.Random(1);
    for (var n = 0; n < 6000; n++) {
      final t = n * SignalProcessor.dt;
      // values are differences between samples, as the logger sends them
      final chirp = (2000 * math.sin(2 * math.pi * (2 + 2 * t) * t)).round();
      final tone = (20 * math.sin(2 * math.pi * 20 * t)).round() + rng.nextInt(5) - 2;
      processor.addLine('$n,$chirp,$tone,${rng.nextInt(9) - 4},${rng.nextInt(9) - 4}');
    }
    await drawPanels(tester, processor, 'synthetic');
  });
}
