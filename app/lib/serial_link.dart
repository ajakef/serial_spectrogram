import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Connection to the Aspen logger over USB serial (Android side is in MainActivity.kt).
/// Splits incoming bytes into text lines and answers the logger's startup prompt.
class SerialLink {
  static const _methods = MethodChannel('aspen/serial');
  static const _events = EventChannel('aspen/serial/events');

  final _lines = StreamController<String>.broadcast();
  final _status = StreamController<String>.broadcast();
  final List<int> _buffer = [];
  StreamSubscription? _sub;

  /// Each complete line from the logger, without the trailing \r\n.
  Stream<String> get lines => _lines.stream;

  /// Connection status: "connected", "disconnected", "no device", "asking permission", "error: ...".
  Stream<String> get status => _status.stream;

  void start() {
    _sub = _events.receiveBroadcastStream().listen((event) {
      if (event is Uint8List) {
        _addBytes(event);
      } else if (event is String) {
        if (event == 'disconnected') _buffer.clear();
        _status.add(event);
      }
    });
    _methods.invokeMethod('connect');
  }

  void connect() => _methods.invokeMethod('connect');

  Future<void> write(String text) =>
      _methods.invokeMethod('write', Uint8List.fromList(utf8.encode(text)));

  void _addBytes(Uint8List bytes) {
    for (final b in bytes) {
      if (b == 0x0A) { // newline
        final line = utf8.decode(_buffer, allowMalformed: true).trim();
        _buffer.clear();
        _handleLine(line);
      } else {
        _buffer.add(b);
      }
    }
  }

  void _handleLine(String line) {
    if (line == 'Enter Serial Number') {
      write('NCM\r\n'); // command for "no compression"
      write('GN:128,32,32,32\r\n'); // standard gains
    }
    _lines.add(line);
  }

  void dispose() {
    _sub?.cancel();
    _methods.invokeMethod('disconnect');
  }
}
