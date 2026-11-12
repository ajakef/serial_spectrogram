import 'dart:async';

import 'package:flutter/material.dart';

import 'firmware_screen.dart';
import 'home_screen.dart';
import 'rate_menu.dart';
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
      home: const HomeScreen(),
    );
  }
}

/// The Plot tab. The connection to the logger belongs to [HomeScreen], which shares it with the other tabs.
class PlotScreen extends StatefulWidget {
  const PlotScreen({super.key, required this.link});

  final SerialLink link;

  @override
  State<PlotScreen> createState() => _PlotScreenState();
}

class _PlotScreenState extends State<PlotScreen> {
  static const redrawInterval = Duration(milliseconds: 50);

  SerialLink get link => widget.link;
  final processor = SignalProcessor();
  final redraw = ValueNotifier<int>(0);
  String status = 'starting';
  bool heardFromAspen = false; // any text received from the logger since connecting
  Timer? _timer;
  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    status = link.currentStatus;
    _subs.add(link.status.listen((s) {
      if (s == 'disconnected') heardFromAspen = false; // the plots stay as they were, so the data is kept
      setState(() => status = s);
    }));
    _subs.add(link.lines.listen((line) {
      if (line == 'Enter Serial Number') _startOver(); // the logger (re)started: its data starts afresh
      heardFromAspen = true;
      processor.addLine(line);
    }));
    _timer = Timer.periodic(redrawInterval, (_) => redraw.value++);
  }

  void _startOver() {
    processor.reset();
    heardFromAspen = false;
  }

  /// A new sample rate from the menu: the plots start afresh, and the Aspen restarts to take the rate at its prompt.
  void _changeRate() {
    setState(_startOver); // also makes the plot buffers the new length
    if (status == 'connected') link.restartLogger();
  }

  Future<void> _openFirmwareScreen() async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => FirmwareScreen(link: link)));
    _startOver(); // the logger restarted, so its data starts afresh
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  /// Message shown over the plots until data is flowing; null when there's nothing to say.
  Widget? _statusCard() {
    final String message;
    final bool busy; // show a spinner: connected, just waiting
    if (status != 'connected' && processor.samples > 0) {
      // The plots keep showing the last data received: say so in a small strip that leaves them visible.
      return Align(
        alignment: Alignment.topCenter,
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Disconnected', style: TextStyle(color: Colors.white)),
              TextButton(onPressed: link.connect, child: const Text('Connect')),
            ],
          ),
        ),
      );
    }
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
            if (status == 'connected') const Positioned(top: 4, left: 4, child: _PlotSettingsNote()),
            Positioned(top: 0, right: 48, child: RateMenu(onChanged: _changeRate)),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                tooltip: 'Update Aspen firmware',
                icon: const Icon(Icons.system_update, color: Colors.black38),
                onPressed: _openFirmwareScreen,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reminder that plotting changes the logger's settings (gains, sample rate, SD errors hidden) until it restarts. Leaving
/// the Plot tab restarts it with CONFIG.TXT's settings; unplugging here doesn't.
class _PlotSettingsNote extends StatelessWidget {
  const _PlotSettingsNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.amber.shade100.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)),
      child: const Text('Plot settings in use: go to Check before unplugging',
          style: TextStyle(fontSize: 11, color: Colors.black87)),
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
