import 'package:flutter/services.dart';

/// Small Android features the app's Kotlin code provides (MainActivity.kt), on the same channel as the USB connection.
class Phone {
  static const _channel = MethodChannel('aspen/serial');

  /// Lets the user choose a file (any size); it's copied into the app's cache. Null if they cancel.
  static Future<({String name, String path})?> pickFileToCache() async {
    final picked = await _channel.invokeMapMethod<String, dynamic>('pickFileToCache');
    if (picked == null) return null;
    return (name: picked['name'] as String, path: picked['path'] as String);
  }

  /// Copies a file into the phone's Download/Aspen folder (visible in the Files app and from a computer). Returns
  /// where it went.
  static Future<String> saveToDownloads(String path, String name, String mimeType) async {
    final where = await _channel.invokeMethod<String>('saveToDownloads', {'path': path, 'name': name, 'mime': mimeType});
    return where ?? 'Download/Aspen/$name';
  }

  /// Magnetic declination (degrees east of true north) at a place, from Android's built-in world magnetic model.
  static Future<double?> declination(double lat, double lon, double altitude) async {
    try {
      return await _channel.invokeMethod<double>('declination', {'lat': lat, 'lon': lon, 'alt': altitude});
    } catch (_) {
      return null;
    }
  }
}
