import 'dart:math' as math;
import 'dart:typed_data';

import 'sample_rate.dart';

/// Parsing, scaling, integration and 1 Hz high-pass filtering of the logger's data lines.
/// Mirrors utils.parse_line in the Python code (including its filter and scaling constants),
/// with two deliberate differences: a data line with fewer than four values has its missing
/// values taken as zero (the logger leaves out trailing zeros) instead of being discarded,
/// and the first [warmup] samples are not stored, since the startup transient would distort the plot
/// scales. The integrated signal carries on through the warm-up, but the filter restarts from zero
/// afterward, as in the Python code.
///
/// Two firmware formats are understood. Older firmware starts each data line with a time code
/// ("1019,6,-4,-3,-7"). Newer firmware (AspenCSV0.4) writes data lines with no time code ("6,-4,-3,-7"),
/// evenly spaced, and sends a T line ("T,...") before its first data line and now and then afterward; the
/// data line after a T line holds absolute values rather than changes. The first T line switches to the newer
/// format. The absolute line after a T line is taken as "no change", which keeps the plot continuous.
class SignalProcessor {
  /// Samples kept: 4096 at 200 Hz (20.48 s), scaled with the sample rate so the plots always span 20.48 s.
  static int get nFull => 4096 * SampleRate.current ~/ SampleRate.standard;
  static const nChan = 4; // infrasound, vertical, north, east
  static double get dt => 1 / SampleRate.current;
  static const cornerFreq = 1.0; // Hz
  static const defaultWarmup = 10; // samples (0.05 s) discarded after startup; same as n_warmup in Python

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

  // First-order Butterworth high-pass, same as scipy.signal.butter(1, corner/nyquist, 'highpass'). Depends on the
  // sample rate, so it's set up again by reset().
  double _b0 = 0, _b1 = 0, _a1 = 0;
  void _setUpFilter() {
    final k = math.tan(math.pi * cornerFreq * dt); // pi * (corner/nyquist) / 2
    _b0 = 1 / (1 + k);
    _b1 = -1 / (1 + k);
    _a1 = (k - 1) / (1 + k);
  }

  SignalProcessor({this.warmup = defaultWarmup}) {
    _setUpFilter();
  }

  final int warmup;

  /// Integrated ("raw") and filtered data, one row per channel. These are ring buffers:
  /// [index] is the position the next sample will be written to. Their length is [nFull], so reset() makes new ones
  /// when the sample rate has changed.
  List<Float64List> raw = List.generate(nChan, (_) => Float64List(nFull));
  List<Float64List> filtered = List.generate(nChan, (_) => Float64List(nFull));
  int index = 0;

  // Most recent sample (the filter's memory). Kept separately because nothing is stored in the buffers
  // during the warm-up.
  final Float64List _lastRaw = Float64List(nChan);
  final Float64List _lastFiltered = Float64List(nChan);

  int accepted = 0; // data lines, including warm-up samples
  int rejected = 0; // non-data lines (startup text and so on)
  int samples = 0; // samples stored in the buffers, after warm-up

  bool _newFormat = false; // a T line has been seen: data lines have no time code
  bool _absoluteNext = false; // the next data line holds absolute values (it follows a T line)

  /// True once the warm-up is over and the buffers are filling with plottable data.
  bool get ready => accepted >= warmup;

  /// Starts over, e.g. after the logger is unplugged or restarts, or the sample rate changes.
  void reset() {
    if (raw[0].length != nFull) {
      raw = List.generate(nChan, (_) => Float64List(nFull));
      filtered = List.generate(nChan, (_) => Float64List(nFull));
    }
    for (var j = 0; j < nChan; j++) {
      raw[j].fillRange(0, nFull, 0);
      filtered[j].fillRange(0, nFull, 0);
    }
    _setUpFilter();
    _lastRaw.fillRange(0, nChan, 0);
    _lastFiltered.fillRange(0, nChan, 0);
    index = 0;
    accepted = 0;
    rejected = 0;
    samples = 0;
    _newFormat = false;
    _absoluteNext = false;
  }

  /// Handles one text line from the logger. Returns true if it was a data line.
  /// Older firmware: a data line is a time code followed by at least one value. Newer firmware (after a
  /// T line): a data line is one or more values. Missing values count as zero.
  /// Anything else (startup messages, T/H/G lines, bare numbers from older firmware) is ignored.
  bool addLine(String line) {
    final trimmed = line.trim();
    if (trimmed.startsWith('T,')) {
      _newFormat = true;
      _absoluteNext = true;
      rejected++;
      return false;
    }
    final fields = trimmed.split(',');
    final first = _newFormat ? 0 : 1; // index of the first value (older firmware puts a time code first)
    if (fields.length < first + 1 || double.tryParse(fields[0]) == null) {
      rejected++;
      return false;
    }
    final values = <double>[];
    for (var j = 0; j < nChan; j++) {
      final v = j + first < fields.length ? double.tryParse(fields[j + first]) : 0.0;
      if (v == null) {
        rejected++;
        return false;
      }
      values.add(v * bitweights[j]);
    }
    if (_absoluteNext) {
      values.fillRange(0, nChan, 0.0); // absolute values, not changes: treat as no change
      _absoluteNext = false;
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
    if (!storing && accepted >= warmup) _lastFiltered.fillRange(0, nChan, 0); // warm-up just ended: restart the filter
    if (storing) {
      index = (i + 1) % nFull;
      samples++;
    }
    return true;
  }
}
