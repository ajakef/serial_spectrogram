import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/app_files.dart';
import 'package:serial_spectrogram/raw_colors.dart';
import 'package:serial_spectrogram/raw_screen.dart';
import 'package:serial_spectrogram/serial_link.dart';

const _red = Color(0xFFC62828);
const _yellow = Color(0xFFFFF59D);

// The test clock is fake; reading and writing files takes real time, so alternate between the two.
Future<void> realIo(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
}

void main() {
  test('delimiters: comma, comma and space, space, runs of spaces, tab, and custom', () {
    List<String> f(Delimiter d, String line) => d.split(line).fields;
    expect(f(Delimiter.comma, 'a,b, c,d'), ['a', 'b', ' c', 'd']);
    expect(f(Delimiter.commaSpace, 'a, b, c,d'), ['a', 'b', 'c,d']);
    expect(f(Delimiter.space, 'a b  c'), ['a', 'b', '', 'c']);
    expect(f(Delimiter.spaces, 'a b   c'), ['a', 'b', 'c']);
    expect(f(Delimiter.tab, 'a\tb\t1.5'), ['a', 'b', '1.5']);
    expect(f(const Delimiter('|'), 'a|b'), ['a', 'b']); // custom text with a special character in a regex
    expect(f(const Delimiter(''), 'a,b'), ['a,b']); // an empty custom separator splits nothing
    expect(Delimiter.spaces.split('a  b  c').separators, ['  ', '  ']);
    expect(Delimiter.tab.appearsIn('x\ty'), true);
    expect(Delimiter.tab.appearsIn('x y'), false);

    // a scheme remembers its delimiter, and colors only lines with the right number of fields for it
    final scheme = RawColorScheme(
        styles: [const FieldStyle(text: _red), const FieldStyle(), const FieldStyle()], delimiter: Delimiter.spaces);
    expect(scheme.span('1   2 3', const TextStyle())!.toPlainText(), '1   2 3'); // spacing kept
    expect(scheme.span('1,2,3', const TextStyle()), isNull);
    expect(scheme.span('1 2', const TextStyle()), isNull);
    final again = RawColorScheme.fromJson(jsonDecode(jsonEncode(scheme.toJson())))!;
    expect(again.delimiter, Delimiter.spaces);
    // a scheme saved before delimiters existed was comma-separated
    expect(RawColorScheme.fromJson({'fields': [{}, {}]})!.delimiter, Delimiter.comma);
  });

  test('a scheme applies only to lines with the same number of fields, and survives saving', () {
    final scheme = RawColorScheme(styles: [
      const FieldStyle(text: _red),
      const FieldStyle(),
      const FieldStyle(highlight: _yellow),
    ]);
    expect(scheme.split('1,2,3'), ['1', '2', '3']);
    expect(scheme.split('1,2'), isNull);
    expect(scheme.split('1,2,3,4'), isNull);
    expect(scheme.split('Firmware: 0.7.0'), isNull);
    final span = scheme.span('10,-5,7', const TextStyle())!;
    expect(span.toPlainText(), '10,-5,7');
    final parts = span.children!.cast<TextSpan>();
    expect(parts.where((p) => p.text == '10').single.style!.color, _red);
    expect(parts.where((p) => p.text == '7').single.style!.backgroundColor, _yellow);
    expect(scheme.span('10,-5', const TextStyle()), isNull);
    scheme.enabled = false;
    expect(scheme.span('10,-5,7', const TextStyle()), isNull); // off

    scheme.enabled = true;
    final again = RawColorScheme.fromJson(jsonDecode(jsonEncode(scheme.toJson())))!;
    expect(again.fields, 3);
    expect(again.styles[0].text, _red);
    expect(again.styles[1].isPlain, true);
    expect(again.styles[2].highlight, _yellow);
    expect(RawColorScheme.fromJson({'junk': 1}), isNull);
  });

  testWidgets('Raw tab: make a scheme from a recent line, see it used on matching lines only, turn it off', (tester) async {
    final dir = Directory.systemTemp.createTempSync('rawcolors');
    addTearDown(() => dir.deleteSync(recursive: true));
    AppFiles.testRoot = dir;
    addTearDown(() => AppFiles.testRoot = null);

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
    aspen.success(Uint8List.fromList(utf8.encode('Firmware: 0.7.0\r\n12,345,-6,7\r\n12,346,-7,8\r\n9,9\r\n')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    bool colored(String line) => tester.widgetList<RichText>(find.byType(RichText)).any((r) =>
        r.text.toPlainText() == line && r.text is TextSpan && (r.text as TextSpan).children?.isNotEmpty == true);

    expect(colored('12,346,-7,8'), false); // no scheme yet

    await tester.tap(find.byIcon(Icons.palette_outlined));
    await tester.pumpAndSettle();
    expect(find.textContaining('exactly 2 fields'), findsOneWidget); // starts from the newest line with commas
    await tester.tap(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == '12,346,-7,8'));
    await tester.pump();
    expect(find.textContaining('exactly 4 fields'), findsOneWidget);
    await tester.tap(find.textContaining('2: 346')); // field 2 of the newest 4-field line
    await tester.pumpAndSettle();
    await tester.tap(find.byWidgetPredicate(
        (w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == _red).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(colored('12,346,-7,8'), true);
    expect(colored('12,345,-6,7'), true);
    expect(colored('9,9'), false); // different number of fields: left alone
    expect(colored('Firmware: 0.7.0'), false);
    await realIo(tester); // file writes
    expect(File('${dir.path}/raw/color_scheme.json').existsSync(), true);

    await tester.tap(find.byType(Checkbox).at(1)); // Colors off
    await tester.pump();
    expect(colored('12,346,-7,8'), false);
    await realIo(tester);
    expect(RawColorScheme.fromJson(jsonDecode(File('${dir.path}/raw/color_scheme.json').readAsStringSync()))!.enabled, false);

    await tester.pumpWidget(const SizedBox());
  });
}
