import 'dart:async';

import 'package:flutter/material.dart';

import 'ble_link.dart';

/// Scans for loggers and shows them in a list; tapping one connects to it. Closing the list stops the scan.
/// Used by the Raw and Plot tabs.
Future<void> chooseBleLogger(BuildContext context, BleLink ble) async {
  await ble.scan();
  if (!context.mounted) return;
  final address = await showDialog<String>(
    context: context,
    builder: (_) => LoggerList(ble: ble),
  );
  if (address != null) {
    await ble.connectTo(address);
  } else if (ble.currentStatus == 'scanning') {
    await ble.disconnect(); // cancelled: stop scanning
  }
}

/// The loggers found by a Bluetooth scan, updated as more appear. Pops with the address of the one tapped.
class LoggerList extends StatefulWidget {
  const LoggerList({super.key, required this.ble});

  final BleLink ble;

  @override
  State<LoggerList> createState() => LoggerListState();
}

class LoggerListState extends State<LoggerList> {
  late List<BleDevice> devices = widget.ble.currentDevices;
  late String status = widget.ble.currentStatus;
  final _subs = <StreamSubscription>[];

  @override
  void initState() {
    super.initState();
    _subs.add(widget.ble.devices.listen((d) => setState(() => devices = d)));
    _subs.add(widget.ble.status.listen((s) {
      if (s.startsWith('error') || s == 'asking permission' || s == 'scanning' || s == 'disconnected') {
        setState(() => status = s);
      }
    }));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scanning = status == 'scanning' || status == 'asking permission';
    final message = status.startsWith('error')
        ? status
        : scanning
            ? 'Looking for loggers...'
            : devices.isEmpty
                ? 'No logger found. Is it on, and not connected to another phone?'
                : 'Scan finished.';
    return AlertDialog(
      title: const Text('Choose a logger'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (scanning) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              if (scanning) const SizedBox(width: 8),
              Expanded(child: Text(message)),
            ]),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final d in devices)
                    ListTile(
                      dense: true,
                      title: Text(d.name),
                      onTap: () => Navigator.pop(context, d.address),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!scanning) TextButton(onPressed: widget.ble.scan, child: const Text('Scan again')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      ],
    );
  }
}
