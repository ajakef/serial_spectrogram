import 'dart:async';

import 'package:flutter/services.dart';

/// Text stream from a logger over Bluetooth Low Energy (the Android side is BleSerial.kt). View-only.
/// Used by the Raw tab as an alternative to the USB cable.
class BleLink {
  static const _methods = MethodChannel('aspen/ble');
  static const _events = EventChannel('aspen/ble/events');

  final _bytes = StreamController<Uint8List>.broadcast();
  final _status = StreamController<String>.broadcast();
  StreamSubscription? _sub;

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
      } else if (event is String) {
        currentStatus = event;
        _status.add(event);
      }
    });
  }

  /// Looks for a logger offering the text stream (up to 15 seconds) and connects to the first one found.
  Future<void> connect() async {
    start();
    await _methods.invokeMethod('connect');
  }

  Future<void> disconnect() => _methods.invokeMethod('disconnect');

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _methods.invokeMethod('disconnect');
    _bytes.close();
    _status.close();
  }
}
