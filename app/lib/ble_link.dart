import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Text stream from a logger over Bluetooth Low Energy (the Android side is BleSerial.kt). View-only.
/// Used by the Raw and Plot tabs as an alternative to the USB cable; [HomeScreen] owns the one connection, so it
/// stays open when the tab changes.
class BleLink {
  static const _methods = MethodChannel('aspen/ble');
  static const _events = EventChannel('aspen/ble/events');

  final _bytes = StreamController<Uint8List>.broadcast();
  final _lines = StreamController<String>.broadcast();
  final List<int> _partial = []; // the unfinished last line
  final _status = StreamController<String>.broadcast();
  final _devices = StreamController<List<BleDevice>>.broadcast();
  StreamSubscription? _sub;

  /// Loggers found by the current scan, as {address, name}.
  List<BleDevice> currentDevices = [];

  /// The list of loggers found so far; a new list is sent each time one more is seen.
  Stream<List<BleDevice>> get devices => _devices.stream;

  /// Latest status, as in [status].
  String currentStatus = 'disconnected';

  /// Every chunk of bytes received, exactly as sent by the logger.
  Stream<Uint8List> get bytes => _bytes.stream;

  /// The same, as complete text lines without their line endings.
  Stream<String> get lines => _lines.stream;

  /// Name of the logger chosen last ("Aspen-00002"), shown while connected.
  String chosenName = '';

  /// "disconnected", "asking permission", "scanning", "connecting to ...", "connected", or "error: ...".
  Stream<String> get status => _status.stream;

  /// True while a connection is being made or is open (so the Connect button should offer to disconnect).
  bool get active =>
      currentStatus == 'connected' || currentStatus == 'scanning' || currentStatus == 'asking permission' || currentStatus.startsWith('connecting');

  void start() {
    _sub ??= _events.receiveBroadcastStream().listen((event) {
      if (event is Uint8List) {
        _bytes.add(event);
        _addLines(event);
      } else if (event is List) {
        currentDevices = [
          for (final d in event) BleDevice(address: (d as Map)['address'] as String, name: d['name'] as String),
        ];
        _devices.add(currentDevices);
      } else if (event is String) {
        if (event == 'connected' || event == 'disconnected') _partial.clear();
        currentStatus = event;
        _status.add(event);
      }
    });
  }

  /// Starts looking for loggers offering the text stream (for 15 seconds); they appear in [devices].
  Future<void> scan() async {
    start();
    await _methods.invokeMethod('connect');
  }

  void _addLines(Uint8List bytes) {
    for (final b in bytes) {
      if (b == 0x0A) {
        _lines.add(latin1.decode(_partial));
        _partial.clear();
      } else if (b != 0x0D && _partial.length < 1000) {
        _partial.add(b);
      }
    }
  }

  /// Connects to one of the loggers in [devices].
  Future<void> connectTo(String address) {
    chosenName = currentDevices.firstWhere((d) => d.address == address, orElse: () => BleDevice(address: address, name: address)).name;
    return _methods.invokeMethod('connectTo', address);
  }

  Future<void> disconnect() => _methods.invokeMethod('disconnect');

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _methods.invokeMethod('disconnect');
    _bytes.close();
    _lines.close();
    _status.close();
    _devices.close();
  }
}

/// A logger seen while scanning.
class BleDevice {
  const BleDevice({required this.address, required this.name});
  final String address;
  final String name;
}
