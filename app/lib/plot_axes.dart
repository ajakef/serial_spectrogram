import 'package:flutter/material.dart';

import 'signal_processor.dart';

/// Layout and drawing shared by the three panels, so their time axes line up.
class PlotAxes {
  static const duration = SignalProcessor.nFull * SignalProcessor.dt; // seconds shown
  static const left = 44.0; // room for frequency labels
  static const right = 12.0;
  static const xLabelHeight = 20.0;
  static const titleHeight = 18.0;

  /// The area inside the axes frame.
  static Rect plotRect(Size size, {required bool title, required bool xLabels}) => Rect.fromLTRB(
      left, title ? titleHeight : 6, size.width - right, size.height - (xLabels ? xLabelHeight : 4));

  /// Horizontal pixel position of time [t] (s).
  static double x(Rect plot, double t) => plot.left + t / duration * plot.width;

  /// Frame, time ticks every 5 s (labelled only on the bottom panel), and optional title.
  static void frame(Canvas canvas, Rect plot, {String? title, bool xLabels = false}) {
    canvas.drawRect(plot, Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1);
    for (var t = 0; t <= duration; t += 5) {
      final px = x(plot, t.toDouble());
      canvas.drawLine(Offset(px, plot.bottom), Offset(px, plot.bottom + 4), Paint()..color = Colors.black);
      if (xLabels) text(canvas, '$t s', Offset(px, plot.bottom + 5), anchorX: 0.5);
    }
    if (title != null) text(canvas, title, Offset(plot.center.dx, plot.top - 2), anchorX: 0.5, anchorY: 1, size: 14);
  }

  /// Black vertical line marking the newest sample.
  static void cursor(Canvas canvas, Rect plot, int index) {
    final px = x(plot, index * SignalProcessor.dt);
    canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), Paint()..color = Colors.black);
  }

  /// Draws text with its anchor point at [at]; anchorX/anchorY are 0 (left/top) to 1 (right/bottom).
  static void text(Canvas canvas, String text, Offset at,
      {double anchorX = 0, double anchorY = 0, double size = 12, bool vertical = false}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: Colors.black, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    if (vertical) { // rotated to read bottom-to-top, centered on [at]
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(-1.5707963267948966);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    } else {
      tp.paint(canvas, at - Offset(tp.width * anchorX, tp.height * anchorY));
    }
  }
}
