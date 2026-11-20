import 'dart:async';

import 'package:flutter/services.dart';

/// Text stream from a logger over Bluetooth Low Energy (the Android side is BleSerial.kt). View-only.
/// Used by the Raw tab as an alternative to the USB cable.
class BleLink {
  static const _methods = MethodChannel('aspen/ble');
  static const _events = EventChannel('aspen/ble/events');

  final _bytes = StreamController<Uint8List>.broadcast();
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

  /// "disconnected", "asking permission", "scanning", "connecting to ...", "connected", or "error: ...".
  Stream<String> get status => _status.stream;

  /// True while a connection is being made or is open (so the Connect button should offer to disconnect).
  bool get active =>
      currentStatus == 'connected' || currentStatus == 'scanning' || currentStatus == 'asking permission' || currentStatus.startsWith('connecting');

  void start() {
    _sub ??= _events.receiveBroadcastStream().listen((event) {
      if (event is Uint8List) {
        _bytes.add(event);
      } else if (event is List) {
        currentDevices = [
          for (final d in event) BleDevice(address: (d as Map)['address'] as String, name: d['name'] as String),
        ];
        _devices.add(currentDevices);
      } else if (event is String) {
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

  /// Connects to one of the loggers in [devices].
  Future<void> connectTo(String address) => _methods.invokeMethod('connectTo', address);

  Future<void> disconnect() => _methods.invokeMethod('disconnect');

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _methods.invokeMethod('disconnect');
    _bytes.close();
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
