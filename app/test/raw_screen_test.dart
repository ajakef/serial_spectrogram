import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/raw_screen.dart';
import 'package:serial_spectrogram/serial_link.dart';

void main() {
  testWidgets('Raw tab shows text, follows the newest line, and changes the baud rate', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    late MockStreamHandlerEventSink aspen;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('aspen/serial'), (call) async {
      calls.add('${call.method} ${call.arguments}');
      return null;
    });
    messenger.setMockStreamHandler(
        const EventChannel('aspen/serial/events'), MockStreamHandler.inline(onListen: (_, sink) {
      aspen = sink;
    }));
    final link = SerialLink()..start();
    await tester.pumpWidget(MaterialApp(home: RawScreen(link: link)));
    aspen.success('connected');
    await tester.pump();

    aspen.success(Uint8List.fromList(utf8.encode('hello\r\nEnter Serial Number')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('Enter Serial Number'), findsOneWidget); // an unfinished line shows too

    // many lines: the newest is visible (autoscroll on), the first is not
    aspen.success(Uint8List.fromList(utf8.encode([for (var i = 0; i < 500; i++) 'line $i\n'].join())));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('line 499'), findsOneWidget);
    expect(find.text('hello'), findsNothing);

    // dragging the text down (toward older lines) turns autoscroll off, and new lines don't move the view
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, false);
    aspen.success(Uint8List.fromList(utf8.encode('newest\n')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('newest'), findsNothing);
    await tester.tap(find.byType(Checkbox)); // back on: jumps to the end
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('newest'), findsOneWidget);

    // baud menu
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9600').last);
    await tester.pumpAndSettle();
    expect(calls, contains('setBaud 9600'));
    expect(link.baud, 9600);

    await tester.pumpWidget(const SizedBox());
  });
}
