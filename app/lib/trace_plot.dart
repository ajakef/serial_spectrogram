import 'package:flutter/material.dart';

import 'plot_axes.dart';
import 'signal_processor.dart';

/// Four stacked waveform traces, like the bottom panel of serial_spectrogram.py.
/// New data overwrites old from left to right; a black line marks the newest sample.
class TracePainter extends CustomPainter {
  TracePainter(this.processor, {super.repaint});

  final SignalProcessor processor;

  static const ylim = 1.0; // vertical axis runs from -ylim to +ylim
  static const plotGains = [-0.125, 1.0, 1.0, 1.0]; // infrasound is flipped and shrunk, as in Python
  static const colors = [Color(0xFFFF0000), Color(0xFFADD8E6), Color(0xFF0000FF), Color(0xFF00008B)];
  static const labels = ['Infrasound', 'Vertical', 'North', 'East'];
  static const labelOffset = 0.15;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = PlotAxes.plotRect(size, title: false, xLabels: true);
    double px(double t) => PlotAxes.x(plot, t);
    double py(double y) => plot.top + (ylim - y) / (2 * ylim) * plot.height;

    PlotAxes.frame(canvas, plot, xLabels: true);
    canvas.save();
    canvas.clipRect(plot);
    final dy = 2 * ylim / SignalProcessor.nChan;
    for (var j = 0; j < SignalProcessor.nChan; j++) {
      final baseline = ylim - dy / 2 - dy * j;
      final data = processor.filtered[j];
      final offset = data[0]; // Python subtracts the first array element, not the oldest sample
      final path = Path();
      for (var i = 0; i < SignalProcessor.nFull; i++) {
        final x = px(i * SignalProcessor.dt);
        final y = py(plotGains[j] * (data[i] - offset) + baseline);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = colors[j]
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round);
      PlotAxes.text(canvas, labels[j], Offset(plot.left + 2, py(baseline + labelOffset)), anchorY: 1);
    }
    PlotAxes.cursor(canvas, plot, processor.index);
    canvas.restore();
  }

  @override
  bool shouldRepaint(TracePainter oldDelegate) => false; // redraws are triggered by the repaint listenable
}
