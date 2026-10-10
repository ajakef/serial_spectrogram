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
      title: 'Serial Spectrogram',
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
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    link.status.listen((s) => setState(() => status = s));
    link.lines.listen(processor.addLine);
    link.start();
    _timer = Timer.periodic(redrawInterval, (_) => redraw.value++);
  }

  @override
  void dispose() {
    _timer?.cancel();
    link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: PlotPanels(processor: processor, redraw: redraw)),
            if (status != 'connected')
              Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Plug in the Aspen logger', style: TextStyle(fontSize: 18)),
                        Text(status, style: const TextStyle(color: Colors.grey)),
                        TextButton(onPressed: link.connect, child: const Text('Connect')),
                      ],
                    ),
                  ),
                ),
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
          child: RepaintBoundary(
            child: CustomPaint(painter: TracePainter(processor, repaint: redraw)),
          ),
        ),
      ],
    );
  }
}
