import 'dart:math' as math;
import 'dart:typed_data';

/// Parsing, scaling, integration and 1 Hz high-pass filtering of the logger's data lines.
/// Mirrors utils.parse_line in the Python code (including its filter and scaling constants),
/// with one deliberate difference: a data line with fewer than four values has its missing
/// values taken as zero (the logger leaves out trailing zeros) instead of being discarded.
class SignalProcessor {
  static const nFull = 4096; // samples kept: 20.48 s at 200 Hz
  static const nChan = 4; // infrasound, vertical, north, east
  static const dt = 0.005;
  static const cornerFreq = 1.0; // Hz

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

  /// Integrated ("raw") and filtered data, one row per channel. These are ring buffers:
  /// [index] is the position the next sample will be written to.
  final List<Float64List> raw = List.generate(nChan, (_) => Float64List(nFull));
  final List<Float64List> filtered = List.generate(nChan, (_) => Float64List(nFull));
  int index = 0;

  int accepted = 0;
  int rejected = 0;

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
    final i = index;
    final prev = (i + nFull - 1) % nFull; // wraps around, like Python's index -1
    for (var j = 0; j < nChan; j++) {
      raw[j][i] = values[j] + raw[j][prev]; // integrate before filtering
      filtered[j][i] = -_a1 * filtered[j][prev] + _b0 * raw[j][i] + _b1 * raw[j][prev];
    }
    index = (i + 1) % nFull;
    accepted++;
    return true;
  }

  /// Most recently written filtered value for a channel (0 before any data arrives).
  double latest(int channel) => filtered[channel][(index + nFull - 1) % nFull];
}
