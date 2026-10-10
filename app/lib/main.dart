import 'dart:async';

import 'package:flutter/material.dart';

import 'serial_link.dart';
import 'signal_processor.dart';
import 'spectrogram_plot.dart';
import 'trace_plot.dart';

void main() => runApp(const SerialSpectrogramApp());

class SerialSpectrogramApp extends StatelessWidget {
  const SerialSpectrogramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aspen Plot',
      theme: ThemeData(brightness: Brightness.light), // plot colors assume a white background
      home: const PlotScreen(),
    );
  }
}

class PlotScreen extends StatefulWidget {
  const PlotScreen({super.key});

  @override
  State<PlotScreen> createState() => _PlotScreenState();
}

class _PlotScreenState extends State<PlotScreen> {
  static const redrawInterval = Duration(milliseconds: 50);

  final link = SerialLink();
  final processor = SignalProcessor();
  final redraw = ValueNotifier<int>(0);
  String status = 'starting';
  bool heardFromAspen = false; // any text received from the logger since connecting
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    link.status.listen((s) {
      if (s == 'disconnected') _startOver();
      setState(() => status = s);
    });
    link.lines.listen((line) {
      if (line == 'Enter Serial Number') _startOver(); // the logger (re)started: its data starts afresh
      heardFromAspen = true;
      processor.addLine(line);
    });
    link.start();
    _timer = Timer.periodic(redrawInterval, (_) => redraw.value++);
  }

  void _startOver() {
    processor.reset();
    heardFromAspen = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    link.dispose();
    super.dispose();
  }

  /// Message shown over the plots until data is flowing; null when there's nothing to say.
  Widget? _statusCard() {
    final String message;
    final bool busy; // show a spinner: connected, just waiting
    if (status != 'connected') {
      message = 'Plug in the Aspen logger';
      busy = false;
    } else if (processor.ready) {
      return null;
    } else if (processor.accepted > 0) {
      message = 'Receiving data...';
      busy = true;
    } else if (heardFromAspen) {
      message = 'Aspen is responding. Waiting for data...';
      busy = true;
    } else {
      message = 'Connected. Waiting for the Aspen...';
      busy = true;
    }
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, style: const TextStyle(fontSize: 18)),
              if (busy)
                const Padding(padding: EdgeInsets.only(top: 12), child: CircularProgressIndicator())
              else ...[
                Text(status, style: const TextStyle(color: Colors.grey)),
                TextButton(onPressed: link.connect, child: const Text('Connect')),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand, // always fill the screen, whether or not the status card is showing
          children: [
            Positioned.fill(child: PlotPanels(processor: processor, redraw: redraw)),
            ValueListenableBuilder<int>(
              valueListenable: redraw, // re-checked at every redraw, since the processor isn't a Listenable
              builder: (context, _, _) => _statusCard() ?? const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The three panels of serial_spectrogram.py, stacked: two spectrograms and the traces.
class PlotPanels extends StatelessWidget {
  const PlotPanels({super.key, required this.processor, required this.redraw});

  final SignalProcessor processor;
  final Listenable redraw;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: RepaintBoundary(
            child: SpectrogramView(processor: processor, channel: 0, title: 'Infrasound', redraw: redraw),
          ),
        ),
        Expanded(
          child: RepaintBoundary(
            child: SpectrogramView(
                processor: processor, channel: 1, title: 'Vertical Seismic', yLabel: 'Frequency (Hz)', redraw: redraw),
          ),
        ),
        Expanded(
          flex: 2, // traces get half the height; each spectrogram a quarter
          child: RepaintBoundary(
            child: CustomPaint(painter: TracePainter(processor, repaint: redraw)),
          ),
        ),
      ],
    );
  }
}
