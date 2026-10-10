import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/spectrogram.dart';

// Compares the app's spectrogram to scipy's (expected_spectrogram.csv, made by
// make_expected_spectrogram.py) for the same made-up test signal.
void main() {
  test('matches scipy.signal.spectrogram', () {
    final rows = File('test/expected_spectrogram.csv')
        .readAsLinesSync()
        .where((l) => !l.startsWith('#') && l.isNotEmpty)
        .map((l) => l.split(',').map(double.parse).toList())
        .toList();
    final x = Float64List(4096);
    for (var n = 0; n < x.length; n++) {
      x[n] = math.sin(0.37 * n) + 0.3 * math.cos(1.91 * n) + 1e-3 * n + 0.05 * math.sin(1.23e-4 * n * n);
    }
    final z = Spectrogram.logPsd(x);
    const nf = Spectrogram.nFreq;
    final times = Spectrogram.times(x.length);

    expect(times.length, rows[0][0].toInt());
    expect(times.first, closeTo(rows[0][1], 1e-12));
    expect(times.last, closeTo(rows[0][2], 1e-12));
    for (final row in rows.skip(1)) {
      final s = row[0].toInt();
      for (var k = 0; k < nf; k++) {
        // log values: absolute tolerance is a relative tolerance on the power
        expect(z[s * nf + k], closeTo(row[k + 1], 1e-6), reason: 'segment $s, frequency $k');
      }
    }
    final noDc = [for (var s = 0; s < times.length; s++) for (var k = 1; k < nf; k++) z[s * nf + k]];
    expect(Spectrogram.quantile(noDc, 0.02), closeTo(rows[0][3], 1e-6));
    expect(Spectrogram.quantile(noDc, 0.98), closeTo(rows[0][4], 1e-6));
  });

  test('silent input gives NaN, not an error', () {
    final z = Spectrogram.logPsd(Float64List(4096));
    expect(z.every((v) => v.isNaN), isTrue);
    expect(Spectrogram.quantile(z, 0.5), isNaN);
  });
}
