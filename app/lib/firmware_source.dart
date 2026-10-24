import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// A firmware file published on GitHub.
class FirmwareRelease {
  FirmwareRelease(this.name, this.url, this.size);
  final String name; // release name, e.g. "0.6.0"
  final String url;
  final int size;
}

/// Finds and downloads firmware from the GitHub releases of the aspen-firmware repo.
/// Releases need a ".bin" file attached (the Arduino IDE's build output, e.g. "aspen-firmware.ino.bin").
class FirmwareSource {
  static const repo = 'ajakef/aspen-firmware';

  Future<HttpClientResponse> _get(HttpClient client, String url) async {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('User-Agent', 'AspenPlot');
    request.headers.set('Accept', 'application/vnd.github+json');
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('GitHub answered ${response.statusCode}');
    }
    return response;
  }

  /// The newest release (pre-releases included) that has a .bin file attached.
  Future<FirmwareRelease> newest() async {
    final client = HttpClient();
    try {
      final response = await _get(client, 'https://api.github.com/repos/$repo/releases?per_page=10');
      final releases = jsonDecode(await response.transform(utf8.decoder).join()) as List;
      for (final release in releases) {
        if (release['draft'] == true) continue;
        for (final asset in release['assets'] as List) {
          if ((asset['name'] as String).toLowerCase().endsWith('.bin')) {
            final name = (release['name'] as String?)?.trim();
            return FirmwareRelease(
                name == null || name.isEmpty ? release['tag_name'] as String : name,
                asset['browser_download_url'] as String,
                asset['size'] as int);
          }
        }
      }
      throw const HttpException('No release with a .bin file was found');
    } finally {
      client.close();
    }
  }

  Future<Uint8List> download(FirmwareRelease release, {void Function(double)? onProgress}) async {
    final client = HttpClient();
    try {
      final response = await _get(client, release.url);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (release.size > 0) onProgress?.call(builder.length / release.size);
      }
      final bytes = builder.takeBytes();
      if (release.size > 0 && bytes.length != release.size) {
        throw const HttpException('The download was incomplete');
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  // The last firmware used (downloaded or chosen from the phone) is kept in the app's private storage.
  Future<String> _dir() async {
    try {
      final dir = await const MethodChannel('aspen/serial').invokeMethod<String>('filesDir');
      if (dir != null) return dir;
    } on PlatformException {
      // fall through
    } on MissingPluginException {
      // fall through
    }
    return Directory.systemTemp.path;
  }

  Future<void> save(String name, Uint8List bytes) async {
    final dir = await _dir();
    await File('$dir/last_firmware.bin').writeAsBytes(bytes, flush: true);
    await File('$dir/last_firmware.txt').writeAsString(name, flush: true);
  }

  /// The firmware used last time, or null.
  Future<({String name, Uint8List bytes})?> saved() async {
    try {
      final dir = await _dir();
      return (name: await File('$dir/last_firmware.txt').readAsString(), bytes: await File('$dir/last_firmware.bin').readAsBytes());
    } on FileSystemException {
      return null;
    }
  }
}
