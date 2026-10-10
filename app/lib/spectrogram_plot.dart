import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'plot_axes.dart';
import 'signal_processor.dart';
import 'spectrogram.dart';
import 'viridis.dart';

/// One spectrogram panel, like the top two panels of serial_spectrogram.py.
/// Recomputed every 128 new samples (as often as Python does); the cursor moves on every redraw.
class SpectrogramView extends StatefulWidget {
  const SpectrogramView({
    super.key,
    required this.processor,
    required this.channel,
    required this.title,
    required this.redraw,
    this.yLabel,
  });

  final SignalProcessor processor;
  final int channel;
  final String title;
  final String? yLabel;
  final Listenable redraw;

  @override
  State<SpectrogramView> createState() => _SpectrogramViewState();
}

class _SpectrogramViewState extends State<SpectrogramView> {
  ui.Image? _image;
  int _lastBlock = -1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.redraw.addListener(_update);
    _update();
  }

  @override
  void dispose() {
    widget.redraw.removeListener(_update);
    _image?.dispose();
    super.dispose();
  }

  void _update() {
    final block = widget.processor.accepted ~/ Spectrogram.nPerSeg;
    if (_busy || block == _lastBlock) return;
    _lastBlock = block;
    _busy = true;
    final pixels = SpectrogramImage.fromData(widget.processor.filtered[widget.channel]);
    ui.decodeImageFromPixels(pixels.rgba, pixels.width, pixels.height, ui.PixelFormat.rgba8888, (image) {
      _busy = false;
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: SpectrogramPainter(
        image: _image,
        processor: widget.processor,
        title: widget.title,
        yLabel: widget.yLabel,
        repaint: widget.redraw,
      ),
    );
  }
}

/// Colored pixels for a spectrogram: one column per segment boundary, one row per frequency band.
/// Follows the Python image() helper: log(PSD) without the 0 Hz row, colors spanning its 2%-98%
/// range, and pcolormesh's habit of dropping the first row and column (Z.T[1:,1:]).
class SpectrogramImage {
  SpectrogramImage(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width; // segments - 1
  final int height; // frequencies - 2; row 0 is the highest frequency

  static const qmin = 0.02, qmax = 0.98;

  static SpectrogramImage fromData(Float64List data) {
    const nf = Spectrogram.nFreq;
    final z = Spectrogram.logPsd(data);
    final nSeg = z.length ~/ nf;
    final noDc = [for (var s = 0; s < nSeg; s++) for (var k = 1; k < nf; k++) z[s * nf + k]];
    final zmin = Spectrogram.quantile(noDc, qmin);
    final zmax = Spectrogram.quantile(noDc, qmax);

    final width = nSeg - 1, height = nf - 2;
    final rgba = Uint8List(width * height * 4); // all transparent until filled
    for (var row = 0; row < height; row++) {
      final k = nf - 1 - row; // frequency index: 64 (100 Hz) at the top down to 2
      for (var col = 0; col < width; col++) {
        final v = z[(col + 1) * nf + k];
        if (v.isNaN) continue;
        final norm = zmax > zmin ? (v - zmin) / (zmax - zmin) : 0.0;
        final color = viridis[(norm * viridis.length).floor().clamp(0, viridis.length - 1)];
        final p = (row * width + col) * 4;
        rgba[p] = (color >> 16) & 0xFF;
        rgba[p + 1] = (color >> 8) & 0xFF;
        rgba[p + 2] = color & 0xFF;
        rgba[p + 3] = 0xFF;
      }
    }
    return SpectrogramImage(rgba, width, height);
  }
}

class SpectrogramPainter extends CustomPainter {
  SpectrogramPainter({required this.image, required this.processor, required this.title, this.yLabel, super.repaint});

  final ui.Image? image;
  final SignalProcessor processor;
  final String title;
  final String? yLabel;

  static const fMin = 1.0, fMax = 100.0; // Hz; the Python tick at 1 Hz extends the axis down to it
  static const freqTicks = [1, 3, 10, 30, 100];

  @override
  void paint(Canvas canvas, Size size) {
    final plot = PlotAxes.plotRect(size, title: true, xLabels: false);
    double py(double f) =>
        plot.bottom - (math.log(f) - math.log(fMin)) / (math.log(fMax) - math.log(fMin)) * plot.height;

    final img = image;
    if (img != null) {
      // Columns are evenly spaced in time; rows are evenly spaced in frequency, so on the
      // logarithmic axis each row gets its own height.
      final times = Spectrogram.times(SignalProcessor.nFull);
      final x0 = PlotAxes.x(plot, times.first), x1 = PlotAxes.x(plot, times.last);
      final paint = Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false;
      for (var row = 0; row < img.height; row++) {
        final k = Spectrogram.nFreq - 1 - row;
        final dest = Rect.fromLTRB(x0, py(Spectrogram.freqs[k]), x1, py(Spectrogram.freqs[k - 1]));
        final src = Rect.fromLTWH(0, row.toDouble(), img.width.toDouble(), 1);
        canvas.drawImageRect(img, src, dest, paint);
      }
    }

    PlotAxes.frame(canvas, plot, title: title);
    for (final f in freqTicks) {
      final y = py(f.toDouble());
      canvas.drawLine(Offset(plot.left - 4, y), Offset(plot.left, y), Paint()..color = Colors.black);
      PlotAxes.text(canvas, '$f', Offset(plot.left - 6, y), anchorX: 1, anchorY: 0.5);
    }
    if (yLabel != null) PlotAxes.text(canvas, yLabel!, Offset(10, plot.center.dy), vertical: true);
    canvas.save();
    canvas.clipRect(plot);
    PlotAxes.cursor(canvas, plot, processor.index);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SpectrogramPainter oldDelegate) => oldDelegate.image != image;
}
