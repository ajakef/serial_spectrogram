import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/firmware_screen.dart';
import 'package:serial_spectrogram/firmware_source.dart';
import 'package:serial_spectrogram/serial_link.dart';

// The firmware screen with a pretend Aspen that prints its startup line whenever RTS pulses.
void main() {
  testWidgets('shows the firmware the Aspen reports, or says it needs firmware', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    late MockStreamHandlerEventSink aspen;
    String? startupText = 'Pins\r\nFirmware: 0.7.0-0_2026-10-07T02:46:36Z\r\nPins initialized\r\n';
    messenger.setMockMethodCallHandler(const MethodChannel('aspen/serial'), (call) async {
      if (call.method == 'setRts' && call.arguments == false && startupText != null) {
        aspen.success(Uint8List.fromList(utf8.encode(startupText)));
      }
      return null;
    });
    messenger.setMockStreamHandler(
        const EventChannel('aspen/serial/events'), MockStreamHandler.inline(onListen: (_, sink) {
      aspen = sink;
    }));

    final link = SerialLink()..start();
    await tester.pumpWidget(MaterialApp(home: FirmwareScreen(link: link)));
    aspen.success('connected');
    await tester.pump();
    expect(find.textContaining('unknown (the Aspen is not connected)'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1)); // checks again below, now that it's connected
    startupText = 'Firmware: 0.7.0-0_2026-10-07T02:46:36Z\r\n';
    await tester.tap(find.text('Check again'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Firmware on the Aspen: 0.7.0-0_2026-10-07T02:46:36Z'), findsOneWidget);

    startupText = null; // blank board: silence
    await tester.tap(find.text('Check again'));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // the check gives up after 4 s
    }
    expect(find.textContaining('needs firmware'), findsOneWidget);
  });

  testWidgets('offers the firmware used last time as the default', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('aspen/serial'), (call) async => null);
    messenger.setMockStreamHandler(const EventChannel('aspen/serial/events'), MockStreamHandler.inline(onListen: (_, sink) {}));
    await tester.pumpWidget(MaterialApp(home: FirmwareScreen(link: SerialLink()..start(), source: _RememberingSource())));
    await tester.pump();
    expect(find.text('Upload aspen_v7.bin'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Download the newest from GitHub'), findsNothing); // no longer the main button
    await tester.pumpWidget(const SizedBox());
  });
}

class _RememberingSource extends FirmwareSource {
  @override
  Future<({String name, Uint8List bytes})?> saved() async => (name: 'aspen_v7.bin', bytes: Uint8List(8));
}
