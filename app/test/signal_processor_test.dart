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
    final processor = SignalProcessor(warmup: 0); // the sample is shorter than the normal warm-up
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
    final p = SignalProcessor(warmup: 0);
    expect(p.addLine('Enter Serial Number'), isFalse);
    expect(p.addLine('128'), isFalse);
    expect(p.addLine('926,10,0,3'), isTrue);
    expect(p.raw[3][0], 0.0); // missing 4th value counts as zero
    expect(p.addLine('931,8,0,2,1'), isTrue);
    expect(p.accepted, 2);
  });

  test('wraps around the end of the buffer continuously', () {
    final p = SignalProcessor(warmup: 0);
    for (var n = 0; n < SignalProcessor.nFull + 5; n++) {
      p.addLine('$n,1,1,1,1');
    }
    expect(p.index, 5);
    // integrated signal keeps growing across the wrap point
    expect(p.raw[0][4], greaterThan(p.raw[0][SignalProcessor.nFull - 1]));
  });

  test('warm-up: first 10 samples are not stored; the integrated signal carries on and the filter restarts', () {
    // a huge startup step, then small wiggles
    String line(int n) => n == 0 ? '0,500000,500000,500000,500000' : '$n,${(n * 7) % 11 - 5},${n % 5 - 2},1,-1';
    final warmed = SignalProcessor();
    final reference = SignalProcessor(warmup: 0); // same data, nothing discarded
    for (var n = 0; n < 1000; n++) {
      warmed.addLine(line(n));
      reference.addLine(line(n));
      if (n == 8) expect(warmed.ready, isFalse);
      if (n == 9) expect(warmed.ready, isTrue);
    }
    expect(warmed.accepted, 1000);
    expect(warmed.samples, 990);
    expect(warmed.index, 990);
    // the integrated signal is the same as with no warm-up, 10 samples later (it includes the startup step)
    for (var k = 0; k < 990; k++) {
      for (var j = 0; j < SignalProcessor.nChan; j++) {
        expect(warmed.raw[j][k], closeTo(reference.raw[j][10 + k], 1e-9));
      }
    }
    // the filter restarts from zero, so the startup step never reaches the stored filtered signal...
    expect(warmed.filtered[0].take(990).map((v) => v.abs()).reduce((a, b) => a > b ? a : b), lessThan(1));
    expect(reference.filtered[0][0].abs(), greaterThan(100)); // ...though the transient is real
    // ...and after the filter's own start-up transient dies away, the two agree
    for (var k = 890; k < 990; k++) {
      expect(warmed.filtered[0][k], closeTo(reference.filtered[0][10 + k], 1e-3));
    }
  });

  test('reset starts over', () {
    final p = SignalProcessor();
    for (var n = 0; n < 500; n++) {
      p.addLine('$n,1,1,1,1');
    }
    expect(p.ready, isTrue);
    p.reset();
    expect(p.ready, isFalse);
    expect(p.accepted, 0);
    expect(p.samples, 0);
    expect(p.index, 0);
  });

  test('newer firmware (AspenCSV0.4): no time code; the line after a T line is absolute', () {
    final p = SignalProcessor(warmup: 0);
    expect(p.addLine('6,-4,-3,-7'), isTrue); // before any T line: older format, so 6 is a time code
    expect(p.raw[0][0], closeTo(-4 * SignalProcessor.bitweights[0], 1e-12));
    final before = [for (var j = 0; j < SignalProcessor.nChan; j++) p.raw[j][0]];

    expect(p.addLine('T,12.345678,1792108800.005,1'), isFalse);
    expect(p.addLine('123456,-654321,7,8'), isTrue); // absolute values: no change
    for (var j = 0; j < SignalProcessor.nChan; j++) {
      expect(p.raw[j][1], closeTo(before[j], 1e-12));
    }
    expect(p.addLine('6,-4,-3,-7'), isTrue); // all four values are changes now
    expect(p.raw[0][2], closeTo(before[0] + 6 * SignalProcessor.bitweights[0], 1e-12));
    expect(p.raw[3][2], closeTo(before[3] - 7 * SignalProcessor.bitweights[3], 1e-12));
    expect(p.addLine('5'), isTrue); // trailing zero changes left out
    expect(p.raw[0][3], closeTo(before[0] + 11 * SignalProcessor.bitweights[0], 1e-12));
    expect(p.raw[1][3], closeTo(p.raw[1][2], 1e-12));
    expect(p.addLine('H,1116,5.12,12.560'), isFalse);

    p.reset(); // e.g. a different logger plugged in: back to the older format until a T line arrives
    expect(p.addLine('5'), isFalse);
  });
}
