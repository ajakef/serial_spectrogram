import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/main.dart';
import 'package:serial_spectrogram/spectrogram_plot.dart';
import 'package:serial_spectrogram/trace_plot.dart';

// Runs the whole app with a pretend logger (no USB), to check the screen layout
// before and after data starts flowing.
void main() {
  testWidgets('plots fill the screen once data arrives', (tester) async {
    const screen = Size(800, 400);
    await tester.binding.setSurfaceSize(screen);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('aspen/serial'), (call) async => null);
    late MockStreamHandlerEventSink logger;
    messenger.setMockStreamHandler(
        const EventChannel('aspen/serial/events'), MockStreamHandler.inline(onListen: (_, sink) {
      logger = sink;
    }));

    await tester.pumpWidget(const SerialSpectrogramApp());
    final full = tester.getSize(find.byType(PlotPanels));
    expect(find.text('Plug in the Aspen logger'), findsOneWidget);

    logger.success('connected');
    logger.success(Uint8List.fromList(utf8.encode('Enter Serial Number\r\n')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Aspen is responding. Waiting for data...'), findsOneWidget);

    final data = StringBuffer();
    for (var n = 0; n < 500; n++) {
      data.write('$n,1,-1,1,-1\r\n');
    }
    logger.success(Uint8List.fromList(utf8.encode(data.toString())));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Waiting'), findsNothing);
    expect(tester.getSize(find.byType(PlotPanels)), full); // didn't shrink when the card went away
    expect(full.width, screen.width);

    // heights: spectrograms a quarter each, traces half
    final spectrogramHeights = tester.widgetList(find.byType(SpectrogramView)).map((w) => tester.getSize(find.byWidget(w)).height);
    final traceHeight = tester.getSize(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TracePainter)).height;
    for (final h in spectrogramHeights) {
      expect(h / full.height, closeTo(0.25, 0.001));
    }
    expect(traceHeight / full.height, closeTo(0.5, 0.001));
  });
}
