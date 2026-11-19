import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/home_screen.dart';
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
    expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, false);
    aspen.success(Uint8List.fromList(utf8.encode('newest\n')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.text('newest'), findsNothing);
    await tester.tap(find.byType(Checkbox).first); // back on: jumps to the end
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

  testWidgets('long lines can be dragged sideways', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    late MockStreamHandlerEventSink aspen;
    messenger.setMockMethodCallHandler(const MethodChannel('aspen/serial'), (call) async => null);
    messenger.setMockStreamHandler(
        const EventChannel('aspen/serial/events'), MockStreamHandler.inline(onListen: (_, sink) {
      aspen = sink;
    }));
    final link = SerialLink()..start();
    await tester.pumpWidget(MaterialApp(home: RawScreen(link: link)));
    aspen.success('connected');
    final text = 'START${'x' * 200}END';
    aspen.success(Uint8List.fromList(utf8.encode('$text\n')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    final x0 = tester.getTopLeft(find.text(text)).dx;
    expect(tester.getTopRight(find.text(text)).dx, greaterThan(tester.view.physicalSize.width / tester.view.devicePixelRatio));
    await tester.drag(find.byType(ListView), const Offset(-3000, 0)); // as far as it goes
    await tester.pump();
    expect(tester.getTopLeft(find.text(text)).dx, lessThan(x0 - 100));
    // the end of the line is now at the right edge (the test font is not exactly monospaced, hence the margin)
    expect(tester.getTopRight(find.text(text)).dx, closeTo(tester.view.physicalSize.width / tester.view.devicePixelRatio, 100));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Raw tab keeps its text and rotation setting when the phone turns', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    late MockStreamHandlerEventSink aspen;
    final orientationCalls = <Object?>[];
    messenger.setMockMethodCallHandler(const MethodChannel('aspen/serial'), (call) async => null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') orientationCalls.add(call.arguments);
      return null;
    });
    messenger.setMockStreamHandler(
        const EventChannel('aspen/serial/events'), MockStreamHandler.inline(onListen: (_, sink) {
      aspen = sink;
    }));
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen(initialTab: HomeScreen.rawTab)));
    aspen.success('connected');
    aspen.success(Uint8List.fromList(utf8.encode('still here\n')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byType(DropdownButton<RawOrientation>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Landscape').last);
    await tester.pumpAndSettle();
    final locks = orientationCalls.length;

    tester.view.physicalSize = const Size(1600, 800); // the phone turns
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('still here'), findsOneWidget);
    expect(find.text('Landscape'), findsOneWidget); // the menu still shows the choice
    expect(orientationCalls.length, locks); // and nothing released the lock
    expect(tester.getSize(find.text('Raw')).width, lessThan(46)); // narrow tab strip down the side
    expect(tester.getTopLeft(find.byType(RawScreen)).dx, lessThan(50));

    await tester.pumpWidget(const SizedBox());
  });
}
