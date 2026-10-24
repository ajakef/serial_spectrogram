import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'firmware_source.dart';
import 'serial_link.dart';
import 'svl_uploader.dart';

/// Second screen: downloads the newest Aspen firmware from GitHub and loads it onto the logger.
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key, required this.link, this.source});

  final SerialLink link;
  final FirmwareSource? source;

  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen> {
  late final FirmwareSource source = widget.source ?? FirmwareSource();
  static final _versionLine = RegExp(r'Firmware: (\S+)[\r\n]');
  String installed = 'checking...'; // firmware now on the Aspen, as it reports at startup
  String message = '';
  double? progress; // 0..1 while downloading or uploading; null when idle
  bool busy = false;
  ({String name, Uint8List bytes})? last; // firmware used last time, offered as the default

  @override
  void initState() {
    super.initState();
    widget.link.rawMode = true; // keep the plotting code from reading bootloader bytes as data
    source.saved().then((saved) {
      if (mounted) setState(() => last = saved);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _show('', isBusy: true);
      await _readInstalled();
      _show('', isBusy: false);
    });
  }

  @override
  void dispose() {
    unawaited(widget.link.endRawMode());
    super.dispose();
  }

  void _show(String text, {double? progressValue, bool? isBusy}) {
    if (!mounted) return;
    setState(() {
      message = text;
      progress = progressValue;
      if (isBusy != null) busy = isBusy;
    });
  }

  /// Restarts the Aspen and reads the "Firmware: ..." line it prints at startup (it prints nothing
  /// if it has no firmware, or firmware too old to report its version). Updates [installed].
  Future<String?> _readInstalled() async {
    final link = widget.link;
    String? version;
    if (link.currentStatus != 'connected') {
      installed = 'unknown (the Aspen is not connected)';
    } else {
      installed = 'checking...';
      _show(message, isBusy: busy);
      try {
        await link.setBaud(500000);
        link.clearInput();
        await SvlUploader.pulseReset(link);
        for (var wait = 0; version == null && wait < 40; wait++) { // up to 4 s
          await Future<void>.delayed(const Duration(milliseconds: 100));
          version = _versionLine.firstMatch(link.rawText)?[1];
        }
        installed = version ?? 'none found. The Aspen needs firmware.';
      } catch (e) {
        installed = 'unknown ($e)';
      }
    }
    _show(message, isBusy: busy);
    return version;
  }

  bool get _connected {
    if (widget.link.currentStatus == 'connected') return true;
    _show('The Aspen is not connected. Plug in the cable, go back, and wait for "connected".');
    return false;
  }

  Future<void> _downloadAndUpdate() async {
    if (!_connected) return;
    _show('Checking GitHub for the newest firmware...', isBusy: true);
    final String name;
    final Uint8List firmware;
    try {
      final release = await source.newest();
      name = release.name;
      _show('Downloading firmware $name...', progressValue: 0);
      firmware = await source.download(release, onProgress: (p) => _show('Downloading firmware $name...', progressValue: p));
    } catch (e) {
      _show('Could not download the firmware ($e). Check the phone\'s internet connection.', isBusy: false);
      return;
    }
    await _upload('$name (GitHub)', firmware);
  }

  Future<void> _updateFromLast() async {
    if (!_connected) return;
    _show('Starting...', isBusy: true);
    await _upload(last!.name, last!.bytes);
  }

  Future<void> _updateFromFile() async {
    if (!_connected) return;
    ({String name, Uint8List bytes})? file;
    try {
      file = await widget.link.pickFile();
    } catch (e) {
      _show('Could not read that file ($e).');
      return;
    }
    if (file == null) return; // cancelled
    _show('Starting...', isBusy: true);
    await _upload(file.name, file.bytes);
  }

  Future<void> _upload(String name, Uint8List firmware) async {
    if (!SvlUploader.looksLikeProgram(firmware)) {
      _show('"$name" does not look like Aspen firmware. Choose the .bin file.', isBusy: false);
      return;
    }
    await source.save(name, firmware); // becomes the default next time
    if (mounted) setState(() => last = (name: name, bytes: firmware));
    try {
      await SvlUploader(widget.link).upload(
        firmware,
        onProgress: (p) => _show('Uploading $name...', progressValue: p),
        onStatus: (s) => _show(s),
      );
      _show('Upload finished. Restarting the Aspen to check...', isBusy: true);
      final version = await _readInstalled();
      _show(
          version == null
              ? 'The upload finished, but the Aspen did not report a firmware version. Try again.'
              : 'Done. The Aspen is now running firmware $version. Go back to see the plots.',
          isBusy: false);
    } catch (e) {
      _show('$e', isBusy: false);
    }
  }

  Widget _button(String label, VoidCallback onPressed, {required bool primary}) {
    final action = busy ? null : onPressed;
    return primary
        ? FilledButton(onPressed: action, child: Text(label))
        : OutlinedButton(onPressed: action, child: Text(label));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !busy, // leaving mid-upload would leave the Aspen without a program
      child: Scaffold(
        appBar: AppBar(title: const Text('Update Aspen firmware')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Loads firmware onto the Aspen through the USB cable: the firmware you used last time, the newest '
                'from GitHub (ajakef/aspen-firmware), or a .bin file saved on the phone (for example an email '
                'attachment). Keep the cable plugged in until it says "Done".',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              Text('Firmware on the Aspen: $installed', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          _show(message, isBusy: true);
                          await _readInstalled();
                          _show(message, isBusy: false);
                        },
                  child: const Text('Check again'),
                ),
              ),
              const SizedBox(height: 8),
              if (last != null) ...[
                FilledButton(
                  onPressed: busy ? null : _updateFromLast,
                  child: Text('Upload ${last!.name}'),
                ),
                const SizedBox(height: 12),
              ],
              _button('Download the newest from GitHub', _downloadAndUpdate, primary: last == null),
              const SizedBox(height: 12),
              _button('Choose a .bin file from this phone', _updateFromFile, primary: false),
              const SizedBox(height: 24),
              if (busy) LinearProgressIndicator(value: progress),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(fontSize: 18)),
            ],
          ),
        ),
      ),
    );
  }
}
