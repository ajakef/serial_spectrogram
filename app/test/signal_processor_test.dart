import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/signal_processor.dart';

// Compares the app's parser to the output of the original Python code
// (expected_sample.csv, made by make_expected.py) on a real logger capture.
void main() {
  test('matches the Python parser on sample_data.txt', () {
    final expected = File('test/expected_sample.csv')
        .readAsLinesSync()
        .where((l) => !l.startsWith('#') && l.isNotEmpty)
        .map((l) => l.split(',').map(double.parse).toList())
        .toList();
    final processor = SignalProcessor();
    var row = 0;
    for (final line in File('sample_data.txt').readAsLinesSync()) {
      if (!processor.addLine(line)) continue;
      final i = processor.index - 1;
      for (var j = 0; j < SignalProcessor.nChan; j++) {
        expect(processor.filtered[j][i], closeTo(expected[row][j], 1e-9), reason: 'filtered, row $row ch $j');
        expect(processor.raw[j][i], closeTo(expected[row][4 + j], 1e-9), reason: 'raw, row $row ch $j');
      }
      row++;
    }
    expect(row, expected.length);
    expect(processor.accepted, expected.length);
    expect(processor.rejected, greaterThan(0)); // startup text
  });

  test('rejects text and bare numbers; short data lines are padded with zeros', () {
    final p = SignalProcessor();
    expect(p.addLine('Enter Serial Number'), isFalse);
    expect(p.addLine('128'), isFalse);
    expect(p.addLine('926,10,0,3'), isTrue);
    expect(p.raw[3][0], 0.0); // missing 4th value counts as zero
    expect(p.addLine('931,8,0,2,1'), isTrue);
    expect(p.accepted, 2);
  });

  test('wraps around the end of the buffer continuously', () {
    final p = SignalProcessor();
    for (var n = 0; n < SignalProcessor.nFull + 5; n++) {
      p.addLine('$n,1,1,1,1');
    }
    expect(p.index, 5);
    // integrated signal keeps growing across the wrap point
    expect(p.raw[0][4], greaterThan(p.raw[0][SignalProcessor.nFull - 1]));
  });
}
