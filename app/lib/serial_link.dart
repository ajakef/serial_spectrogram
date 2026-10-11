import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'svl_uploader.dart';

/// Connection to the Aspen logger over USB serial (Android side is in MainActivity.kt).
/// Splits incoming bytes into text lines and answers the logger's startup prompt.
class SerialLink implements SvlPort {
  static const _methods = MethodChannel('aspen/serial');
  static const _events = EventChannel('aspen/serial/events');

  final _lines = StreamController<String>.broadcast();
  final _status = StreamController<String>.broadcast();
  final List<int> _buffer = [];
  StreamSubscription? _sub;

  /// While true (during a firmware update), incoming bytes are held for readBytes() instead of
  /// being split into lines, and the logger's startup prompt isn't answered.
  bool rawMode = false;
  final List<int> _raw = [];
  Completer<void>? _rawArrived;

  /// Latest status, as in [status].
  String currentStatus = 'starting';

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
        currentStatus = event;
        _status.add(event);
      }
    });
    _methods.invokeMethod('connect');
  }

  void connect() => _methods.invokeMethod('connect');

  Future<void> write(String text) =>
      _methods.invokeMethod('write', Uint8List.fromList(utf8.encode(text)));

  @override
  Future<void> writeBytes(List<int> bytes) => _methods.invokeMethod('write', Uint8List.fromList(bytes));

  /// Lets the user choose a file on the phone. Null if they cancel.
  Future<({String name, Uint8List bytes})?> pickFile() async {
    final picked = await _methods.invokeMapMethod<String, dynamic>('pickFile');
    if (picked == null) return null;
    return (name: picked['name'] as String, bytes: picked['bytes'] as Uint8List);
  }

  @override
  Future<void> setBaud(int baud) => _methods.invokeMethod('setBaud', baud);

  @override
  Future<void> setRts(bool asserted) => _methods.invokeMethod('setRts', asserted);

  /// Text received so far in raw mode (not removed from the buffer).
  String get rawText => utf8.decode(_raw, allowMalformed: true);

  @override
  void clearInput() => _raw.clear();

  @override
  Future<Uint8List?> readBytes(int count, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_raw.length < count) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      final arrived = _rawArrived = Completer<void>();
      await arrived.future.timeout(remaining, onTimeout: () {});
    }
    final bytes = Uint8List.fromList(_raw.sublist(0, count));
    _raw.removeRange(0, count);
    return bytes;
  }

  /// Back to normal plotting: the logger's data rate, and the same control-line state as when connecting.
  Future<void> endRawMode() async {
    rawMode = false;
    _raw.clear();
    _buffer.clear();
    await setBaud(500000);
    await setRts(true);
  }

  void _addBytes(Uint8List bytes) {
    if (rawMode) {
      _raw.addAll(bytes);
      _rawArrived?.complete();
      _rawArrived = null;
      return;
    }
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
      write('GN:128,32,32,32\r\n\n'); // standard gains; the extra blank line tells the logger no more commands are coming, so it skips its wait
    }
    _lines.add(line);
  }

  void dispose() {
    _sub?.cancel();
    _methods.invokeMethod('disconnect');
  }
}
