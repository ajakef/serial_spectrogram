import 'dart:io';

import 'package:flutter/services.dart';

/// Folders inside the app's private storage on the phone (Android deletes them if the app is uninstalled, so the
/// Sites tab exports copies). Tests set [testRoot] to use a temporary folder instead.
class AppFiles {
  static Directory? testRoot;

  static Future<Directory> dir(String name) async {
    var base = testRoot?.path;
    if (base == null) {
      try {
        base = await const MethodChannel('aspen/serial').invokeMethod<String>('filesDir');
      } catch (_) {}
      base ??= Directory.systemTemp.path;
    }
    final d = Directory('$base/$name');
    await d.create(recursive: true);
    return d;
  }
}

/// "2026-11-12T04:44:39.298Z": UTC with milliseconds, as in the bench recorder's serial captures.
String isoMillis(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.'
      '${u.millisecond.toString().padLeft(3, '0')}Z';
}

/// "20261112_044439" (UTC), for file names.
String fileStamp(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}${two(u.month)}${two(u.day)}_${two(u.hour)}${two(u.minute)}${two(u.second)}';
}
