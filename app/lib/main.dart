import 'dart:async';

import 'package:flutter/material.dart';

import 'ble_link.dart';
import 'boot_report.dart';
import 'firmware_screen.dart';
import 'home_screen.dart';
import 'logger_chooser.dart';
import 'rate_menu.dart';
import 'sample_rate.dart';
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

/// The Plot tab. The connections to the logger (USB and Bluetooth) belong to [HomeScreen], which shares them with the
/// other tabs. Over USB the app sets the logger's rate and gains (it restarts the logger to do so); over Bluetooth it
/// plots the logger as it runs, with the rate and gains from the "Config:" line the logger sends first.
class PlotScreen extends StatefulWidget {
  const PlotScreen({super.key, required this.link, required this.ble});

  final SerialLink link;
  final BleLink ble;

  @override
  State<PlotScreen> createState() => _PlotScreenState();
}

class _PlotScreenState extends State<PlotScreen> {
  static const redrawInterval = Duration(milliseconds: 50);

  SerialLink get link => widget.link;
  BleLink get ble => widget.ble;
  final processor = SignalProcessor();
  late bool bluetooth = ble.active; // plotting over Bluetooth (USB lines are ignored meanwhile)
  late String bleStatus = ble.currentStatus;
  LoggerSettings? bleSettings; // the Bluetooth logger's settings, from its "Config:" line
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
      if (bluetooth) return;
      if (line == 'Enter Serial Number') _startOver(); // the logger (re)started: its data starts afresh
      heardFromAspen = true;
      processor.addLine(line);
    }));
    _subs.add(ble.status.listen((s) {
      if (s == 'connected') {
        bleSettings = null;
        _startOver();
      }
      setState(() => bleStatus = s);
    }));
    _subs.add(ble.lines.listen((line) {
      if (!bluetooth) return;
      final settings = LoggerSettings.parse(line);
      if (settings != null) {
        _useLoggerSettings(settings);
        return;
      }
      heardFromAspen = true;
      processor.addLine(line);
    }));
    _timer = Timer.periodic(redrawInterval, (_) => redraw.value++);
  }

  void _startOver() {
    processor.reset();
    heardFromAspen = false;
  }

  /// Over Bluetooth: plot at the logger's own rate and scale for its gains.
  void _useLoggerSettings(LoggerSettings settings) {
    bleSettings = settings;
    if (SampleRate.choices.contains(settings.sampleRate)) SampleRate.current = settings.sampleRate;
    processor.setGains(settings.gains);
    _startOver(); // also makes the plot buffers the new length
    setState(() {});
  }

  Future<void> _useBluetooth() async {
    setState(() => bluetooth = true);
    await chooseBleLogger(context, ble);
    if (mounted && !ble.active) setState(() => bluetooth = ble.active); // cancelled
  }

  /// Back to the USB cable: Bluetooth disconnects, and the USB logger's data (at the app's settings) are plotted.
  void _useUsb() {
    ble.disconnect();
    processor.setGains(SignalProcessor.defaultGains);
    setState(() {
      bluetooth = false;
      _startOver();
    });
    if (status == 'connected') link.restartLogger(); // a USB logger takes the app's rate and gains again
  }

  /// Connection status of whichever link is plotted.
  String get shownStatus => bluetooth ? bleStatus : status;

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
    final status = shownStatus;
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
              TextButton(onPressed: bluetooth ? _useBluetooth : link.connect, child: const Text('Connect')),
            ],
          ),
        ),
      );
    }
    if (bluetooth && status != 'connected' && status != 'disconnected' && !status.startsWith('error')) {
      message = 'Connecting over Bluetooth...';
      busy = true;
    } else if (status != 'connected') {
      message = bluetooth ? 'Not connected over Bluetooth' : 'Plug in the Aspen logger';
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
                Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(onPressed: bluetooth ? _useUsb : link.connect, child: const Text('USB')),
                  TextButton(onPressed: _useBluetooth, child: const Text('Bluetooth')),
                ]),
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
            if (!bluetooth && status == 'connected') const Positioned(top: 4, left: 4, child: _PlotSettingsNote()),
            if (bluetooth && bleStatus == 'connected')
              Positioned(
                top: 4,
                left: 4,
                child: _BluetoothNote(name: ble.chosenName, rate: bleSettings?.sampleRate, onClose: _useUsb),
              ),
            if (!bluetooth) Positioned(top: 0, right: 48, child: RateMenu(onChanged: _changeRate)),
            if (!bluetooth)
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

/// Over Bluetooth: which logger is plotted, at what rate, and an X to stop (back to USB).
class _BluetoothNote extends StatelessWidget {
  const _BluetoothNote({required this.name, required this.rate, required this.onClose});

  final String name;
  final int? rate;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(color: Colors.lightBlue.shade50.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.bluetooth, size: 14, color: Colors.black54),
        Text(' $name${rate == null ? '' : ', $rate sps'}', style: const TextStyle(fontSize: 11, color: Colors.black87)),
        InkWell(
          onTap: onClose,
          child: const Padding(padding: EdgeInsets.all(4), child: Icon(Icons.close, size: 14, color: Colors.black54)),
        ),
      ]),
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
