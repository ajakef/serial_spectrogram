import 'dart:math' as math;
import 'dart:typed_data';

/// Spectrogram matching scipy.signal.spectrogram(x, fs=200, window='hamming', nperseg=128,
/// noverlap=112, detrend='linear') followed by log(), as in serial_spectrogram.py.
class Spectrogram {
  static const fs = 200.0;
  static const nPerSeg = 128;
  static const overlap = 0.875;
  static const step = nPerSeg - (overlap * nPerSeg) ~/ 1; // 16 samples between segments
  static const nFreq = nPerSeg ~/ 2 + 1; // 65 frequencies, 0 to 100 Hz

  /// Frequency of each row (Hz).
  static final List<double> freqs = [for (var k = 0; k < nFreq; k++) k * fs / nPerSeg];

  /// Time of each column (s): the center of each segment.
  static List<double> times(int nSamples) =>
      [for (var s = 0; s < segments(nSamples); s++) (s * step + nPerSeg / 2) / fs];

  static int segments(int nSamples) => (nSamples - nPerSeg) ~/ step + 1;

  // Periodic Hamming window, as scipy.signal.get_window('hamming', 128) returns.
  static final Float64List _window = Float64List.fromList(
      [for (var n = 0; n < nPerSeg; n++) 0.54 - 0.46 * math.cos(2 * math.pi * n / nPerSeg)]);
  static final double _scale = 1 / (fs * _window.fold(0.0, (sum, w) => sum + w * w)); // 'density' scaling

  /// log(power spectral density), indexed [segment * nFreq + frequency].
  /// Zero power gives NaN (Python turns zeros into NaN before taking the log).
  static Float64List logPsd(Float64List x) {
    final nSeg = segments(x.length);
    final out = Float64List(nSeg * nFreq);
    final re = Float64List(nPerSeg);
    final im = Float64List(nPerSeg);
    for (var s = 0; s < nSeg; s++) {
      _detrendAndWindow(x, s * step, re);
      im.fillRange(0, nPerSeg, 0);
      _fft(re, im);
      for (var k = 0; k < nFreq; k++) {
        var p = (re[k] * re[k] + im[k] * im[k]) * _scale;
        if (k > 0 && k < nFreq - 1) p *= 2; // one-sided spectrum: fold in negative frequencies
        out[s * nFreq + k] = p == 0 ? double.nan : math.log(p);
      }
    }
    return out;
  }

  /// Copies one segment into [out], removing its least-squares straight line and applying the window.
  static void _detrendAndWindow(Float64List x, int start, Float64List out) {
    const n = nPerSeg;
    const tMean = (n - 1) / 2;
    var xMean = 0.0;
    for (var i = 0; i < n; i++) {
      xMean += x[start + i];
    }
    xMean /= n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      num += (i - tMean) * (x[start + i] - xMean);
      den += (i - tMean) * (i - tMean);
    }
    final slope = num / den;
    for (var i = 0; i < n; i++) {
      out[i] = (x[start + i] - xMean - slope * (i - tMean)) * _window[i];
    }
  }

  // In-place radix-2 FFT (length must be a power of 2).
  static void _fft(Float64List re, Float64List im) {
    final n = re.length;
    for (var i = 1, j = 0; i < n; i++) { // bit-reversal permutation
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i]; re[i] = re[j]; re[j] = t;
        t = im[i]; im[i] = im[j]; im[j] = t;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = -2 * math.pi / len;
      for (var i = 0; i < n; i += len) {
        for (var k = 0; k < len ~/ 2; k++) {
          final wr = math.cos(ang * k), wi = math.sin(ang * k);
          final a = i + k, b = i + k + len ~/ 2;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr; im[b] = im[a] - xi;
          re[a] += xr; im[a] += xi;
        }
      }
    }
  }

  /// Same as numpy.quantile (linear interpolation), ignoring NaN. Returns NaN if there's no data.
  static double quantile(Iterable<double> values, double q) {
    final v = values.where((x) => x.isFinite).toList()..sort();
    if (v.isEmpty) return double.nan;
    final h = (v.length - 1) * q;
    final lo = h.floor();
    final hi = math.min(lo + 1, v.length - 1);
    return v[lo] + (h - lo) * (v[hi] - v[lo]);
  }
}
