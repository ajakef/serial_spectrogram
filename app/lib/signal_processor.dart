import 'dart:math' as math;
import 'dart:typed_data';

/// Parsing, scaling, integration and 1 Hz high-pass filtering of the logger's data lines.
/// Mirrors utils.parse_line in the Python code (including its filter and scaling constants),
/// with two deliberate differences: a data line with fewer than four values has its missing
/// values taken as zero (the logger leaves out trailing zeros) instead of being discarded,
/// and the first [warmup] samples are filtered but not stored, since the startup transient
/// (huge values for the first second or two) would distort the plot scales.
class SignalProcessor {
  static const nFull = 4096; // samples kept: 20.48 s at 200 Hz
  static const nChan = 4; // infrasound, vertical, north, east
  static const dt = 0.005;
  static const cornerFreq = 1.0; // Hz
  static const defaultWarmup = 400; // samples (2 s) discarded after startup; same as n_warmup in Python

  // Same values as utils.py. The firmware divides gains by 16 "to avoid writing noise bits".
  static const _bitweightV = 5 / (1 << 24); // differential measurement goes up to +/- 2.5 V
  static const _sensitivityInfrasound = 0.01 / 125 * 3.2 / 12; // V/Pa
  static const _sensitivitySeismic = 30; // V/m/s; probably order-of-magnitude accurate
  static const _gainInfrasound = 128 / 16;
  static const _gainSeismic = 32 / 16;
  static final List<double> bitweights = [
    _bitweightV / _gainInfrasound / _sensitivityInfrasound,
    for (var i = 1; i < nChan; i++) _bitweightV / _gainSeismic / _sensitivitySeismic * 1e3, // mm/s
  ];

  // First-order Butterworth high-pass, same as scipy.signal.butter(1, corner/nyquist, 'highpass').
  static final double _k = math.tan(math.pi * cornerFreq * dt); // pi * (corner/nyquist) / 2
  static final double _b0 = 1 / (1 + _k);
  static final double _b1 = -1 / (1 + _k);
  static final double _a1 = (_k - 1) / (1 + _k);

  SignalProcessor({this.warmup = defaultWarmup});

  final int warmup;

  /// Integrated ("raw") and filtered data, one row per channel. These are ring buffers:
  /// [index] is the position the next sample will be written to.
  final List<Float64List> raw = List.generate(nChan, (_) => Float64List(nFull));
  final List<Float64List> filtered = List.generate(nChan, (_) => Float64List(nFull));
  int index = 0;

  // Most recent sample (the filter's memory). Kept separately so it survives the warm-up,
  // when nothing is stored in the buffers.
  final Float64List _lastRaw = Float64List(nChan);
  final Float64List _lastFiltered = Float64List(nChan);

  int accepted = 0; // data lines, including warm-up samples
  int rejected = 0; // non-data lines (startup text and so on)
  int samples = 0; // samples stored in the buffers, after warm-up

  /// True once the warm-up is over and the buffers are filling with plottable data.
  bool get ready => accepted >= warmup;

  /// Starts over, e.g. after the logger is unplugged or restarts.
  void reset() {
    for (var j = 0; j < nChan; j++) {
      raw[j].fillRange(0, nFull, 0);
      filtered[j].fillRange(0, nFull, 0);
    }
    _lastRaw.fillRange(0, nChan, 0);
    _lastFiltered.fillRange(0, nChan, 0);
    index = 0;
    accepted = 0;
    rejected = 0;
    samples = 0;
  }

  /// Handles one text line from the logger. Returns true if it was a data line.
  /// A data line is a time code followed by at least one value; missing values count as zero.
  /// Anything else (startup messages, bare numbers) is ignored.
  bool addLine(String line) {
    final fields = line.trim().split(',');
    if (fields.length < 2 || double.tryParse(fields[0]) == null) {
      rejected++;
      return false;
    }
    final values = <double>[];
    for (var j = 0; j < nChan; j++) {
      final v = j + 1 < fields.length ? double.tryParse(fields[j + 1]) : 0.0;
      if (v == null) {
        rejected++;
        return false;
      }
      values.add(v * bitweights[j]);
    }
    final storing = ready;
    final i = index;
    for (var j = 0; j < nChan; j++) {
      final newRaw = values[j] + _lastRaw[j]; // integrate before filtering
      final newFiltered = -_a1 * _lastFiltered[j] + _b0 * newRaw + _b1 * _lastRaw[j];
      _lastRaw[j] = newRaw;
      _lastFiltered[j] = newFiltered;
      if (storing) {
        raw[j][i] = newRaw;
        filtered[j][i] = newFiltered;
      }
    }
    accepted++;
    if (storing) {
      index = (i + 1) % nFull;
      samples++;
    }
    return true;
  }
}
