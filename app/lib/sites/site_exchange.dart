import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:image/image.dart' as img;

import '../app_files.dart';
import '../boot_report.dart';
import '../check_session.dart';
import 'site_model.dart';
import 'site_store.dart';

/// Exporting sites to one zip file (to send to another phone or a computer) and importing such a file (merging it with
/// the sites already on this phone). The zip holds tables for people (CSV, KML for Google Earth, photos with the
/// markers drawn on) and sites.json, which is what the app reads back.

const exportFormat = 'aspen-sites';
const exportVersion = 1;

String _csv(List<List<Object?>> rows) => rows
    .map((r) => r.map((v) {
          final s = v?.toString() ?? '';
          return s.contains(RegExp('[",\n\r]')) ? '"${s.replaceAll('"', '""')}"' : s;
        }).join(','))
    .join('\n');

String _iso(DateTime? t) => t == null ? '' : t.toUtc().toIso8601String();

String _xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// The channel codes the logger will write: the site's own, or the default for its sample rate (blank if unknown).
List<String> resolvedChannels(Site s) => [
      for (var i = 0; i < 4; i++)
        s.channels[i].isNotEmpty
            ? s.channels[i]
            : (s.sampleRate == null ? '' : BootReport.defaultChannelCode(i, s.sampleRate!)),
    ];

/// Names for the marked-up copies: "KIRK1_20261112_1.jpg".
String markedPhotoName(Site s, Visit v, int index) {
  final name = s.title.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return '${name}_${fileStamp(v.time).substring(0, 8)}_${index + 1}.jpg';
}

const readme = '''Aspen field sites, exported from the Aspen Plot app.

sites.csv       One row per site: serial number, SEED codes, waypoint, setup and pickup times.
visits.csv      One row per visit (setup, service, pickup), with its notes.
photos.csv      One row per photo, with its markers (label and position as fractions of the
                photo's width and height, measured from the top left).
sites.kml       The waypoints, for Google Earth (File > Open) and most mapping programs.
sites.json      All of the above in one file; the app reads this when importing.
photos/         The photos as taken: photos/<site id>/<photo id>.jpg.
photos_marked/  The same photos with the markers drawn on, named station_date_number.jpg.
startup_logs/   The Check tab's logs saved during these visits, if any.

Notes on the columns:
- Times are UTC (ISO 8601).
- latitude and longitude are WGS84 degrees, averaged over the phone's GPS fixes at the waypoint;
  horizontal_accuracy_m is the phone's estimate for its best fix (about 68% confidence).
- elevation_m is the phone's GPS altitude: above sea level on Android 14 and later, otherwise above the
  WGS84 ellipsoid (tens of meters different). The logger's own GPS positions, averaged over the
  deployment, are more accurate for station metadata.
- channel1-channel4 are SEED channel codes. Blank codes in the app mean the logger's default, filled
  in here when the sample rate is known (it is when the site was filled in from the Check tab).

To merge this into the app on another phone: Sites tab, menu, Import, and choose this zip file.
''';

/// Writes the export zip into the app's exports folder and returns it. [progress] gets short status messages.
Future<File> exportSites(SiteStore store, List<Site> sites, {void Function(String)? progress}) async {
  final dir = await AppFiles.dir('exports');
  for (final old in dir.listSync().whereType<File>()) {
    old.deleteSync(); // only the newest export is kept here; copies sent or saved elsewhere stay there
  }
  final zip = File('${dir.path}/aspen_sites_${fileStamp(DateTime.now())}.zip');
  final out = ZipFileEncoder()..create(zip.path);
  final logs = await AppFiles.dir(LogRecorder.folder);

  final siteRows = <List<Object?>>[
    ['site_id', 'serial_number', 'network', 'station', 'location', 'channel1', 'channel2', 'channel3', 'channel4',
      'sample_rate', 'latitude', 'longitude', 'elevation_m', 'horizontal_accuracy_m', 'gps_fixes', 'waypoint_time',
      'setup_time', 'pickup_time', 'visits', 'photos'],
  ];
  final visitRows = <List<Object?>>[
    ['site_id', 'station', 'visit_id', 'time', 'kind', 'photos', 'startup_log', 'notes'],
  ];
  final photoRows = <List<Object?>>[
    ['site_id', 'station', 'visit_id', 'visit_time', 'photo', 'marked_photo', 'taken', 'markers'],
  ];
  final kml = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n'
      '<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Aspen sites</name>\n');

  var done = 0;
  final total = sites.fold<int>(0, (n, s) => n + s.liveVisits.fold<int>(0, (m, v) => m + v.livePhotos.length));
  for (final s in sites) {
    final w = s.waypoint;
    final visits = s.liveVisits.toList()..sort((a, b) => a.time.compareTo(b.time));
    final channels = resolvedChannels(s);
    siteRows.add([
      s.id, s.serialNumber, s.network, s.station, s.location, ...channels, s.sampleRate,
      w?.lat.toStringAsFixed(7), w?.lon.toStringAsFixed(7), w?.altitude?.toStringAsFixed(1),
      w?.accuracy?.toStringAsFixed(1), w?.fixes, _iso(w?.time),
      _iso(s.timeOf(VisitKind.setup)), _iso(s.timeOf(VisitKind.pickup)),
      visits.length, visits.fold<int>(0, (n, v) => n + v.livePhotos.length),
    ]);
    if (w != null) {
      final description = [
        'Serial number: ${s.serialNumber}',
        'SEED: ${s.network}.${s.station}.${s.location} ${channels.where((c) => c.isNotEmpty).join(' ')}',
        for (final v in visits) '${_iso(v.time)} ${v.kind.label}: ${v.notes}',
      ].join('\n');
      kml.write('<Placemark><name>${_xml(s.title)}</name><description>${_xml(description)}</description>'
          '<Point><coordinates>${w.lon},${w.lat},${w.altitude ?? 0}</coordinates></Point></Placemark>\n');
    }
    for (final v in visits) {
      final photos = v.livePhotos.toList();
      visitRows.add([s.id, s.station, v.id, _iso(v.time), v.kind.label, photos.length, v.startupLog ?? '', v.notes]);
      if (v.startupLog != null) {
        final log = File('${logs.path}/${v.startupLog}');
        if (log.existsSync()) await out.addFile(log, 'startup_logs/${v.startupLog}');
      }
      for (var i = 0; i < photos.length; i++) {
        final p = photos[i];
        final f = store.photoFile(s, p);
        final marked = markedPhotoName(s, v, i);
        photoRows.add([
          s.id, s.station, v.id, _iso(v.time), 'photos/${s.id}/${p.fileName}', 'photos_marked/$marked', _iso(p.taken),
          p.markers.map((m) => '${m.label} (${m.x.toStringAsFixed(3)}, ${m.y.toStringAsFixed(3)})').join('; '),
        ]);
        if (!f.existsSync()) continue;
        progress?.call('Photo ${++done} of $total');
        await out.addFile(f, 'photos/${s.id}/${p.fileName}', 0); // JPEGs don't compress: store them as they are
        final bytes = await f.readAsBytes();
        final markers = [for (final m in p.markers) (m.x, m.y, m.label)];
        final drawn = await Isolate.run(() => drawMarkers(bytes, markers));
        if (drawn != null) out.addArchiveFile(ArchiveFile.bytes('photos_marked/$marked', drawn)..compression = CompressionType.none);
      }
    }
  }
  kml.write('</Document></kml>\n');
  progress?.call('Writing the tables');
  out.addArchiveFile(ArchiveFile.string('README.txt', readme));
  out.addArchiveFile(ArchiveFile.string('sites.csv', '${_csv(siteRows)}\n'));
  out.addArchiveFile(ArchiveFile.string('visits.csv', '${_csv(visitRows)}\n'));
  out.addArchiveFile(ArchiveFile.string('photos.csv', '${_csv(photoRows)}\n'));
  out.addArchiveFile(ArchiveFile.string('sites.kml', kml.toString()));
  out.addArchiveFile(ArchiveFile.string(
    'sites.json',
    const JsonEncoder.withIndent(' ').convert({
      'format': exportFormat,
      'version': exportVersion,
      'exported': _iso(DateTime.now()),
      'sites': [for (final s in sites) s.toJson()],
    }),
  ));
  await out.close();
  return zip;
}

/// A copy of a photo with its markers drawn on (a ring, a dot, and the label), as JPEG; null if it can't be read.
/// Runs in the background (Isolate.run), since decoding a photo takes about a second.
Uint8List? drawMarkers(Uint8List jpeg, List<(double, double, String)> markers) {
  final decoded = img.decodeJpg(jpeg);
  if (decoded == null) return null;
  final photo = img.bakeOrientation(decoded); // the way it looks on screen, where the markers were placed
  final size = photo.width < photo.height ? photo.width : photo.height;
  final r = (size / 40).round().clamp(8, 60);
  final font = size >= 1200 ? img.arial48 : img.arial24;
  final yellow = img.ColorRgb8(255, 220, 0);
  final black = img.ColorRgb8(0, 0, 0);
  for (final (fx, fy, label) in markers) {
    final x = (fx * photo.width).round(), y = (fy * photo.height).round();
    for (var t = 0; t < (r / 4).ceil(); t++) {
      img.drawCircle(photo, x: x, y: y, radius: r + t, color: yellow);
    }
    img.fillCircle(photo, x: x, y: y, radius: (r / 4).ceil(), color: yellow);
    final tx = x + r + 6, ty = y - font.lineHeight ~/ 2;
    img.fillRect(photo,
        x1: tx - 4, y1: ty - 2, x2: tx + label.length * font.base ~/ 2 + 8, y2: ty + font.lineHeight + 2, color: black);
    img.drawString(photo, label, font: font, x: tx, y: ty, color: yellow);
  }
  return img.encodeJpg(photo, quality: 85);
}

class ImportResult {
  ImportResult(this.added, this.updated, this.photos);
  final int added;
  final int updated;
  final int photos;
}

/// Reads an export zip and merges its sites into [store]. Throws a FormatException with a plain message if the file
/// isn't an export.
Future<ImportResult> importSites(SiteStore store, String zipPath) async {
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (_) {
      throw const FormatException('That isn\'t a zip file exported from the Sites tab.');
    }
    ArchiveFile? find(String name) {
      for (final f in archive.files) {
        if (f.isFile && (f.name == name || f.name.endsWith('/$name'))) return f;
      }
      return null;
    }

    final json = find('sites.json');
    if (json == null) throw const FormatException('That zip file has no sites.json: is it an export from the Sites tab?');
    final data = jsonDecode(utf8.decode(json.content));
    if (data is! Map || data['format'] != exportFormat) {
      throw const FormatException('That sites.json wasn\'t made by the Sites tab.');
    }
    if ((data['version'] as num? ?? 0) > exportVersion) {
      throw const FormatException('That file is from a newer version of the app: update this phone\'s app first.');
    }
    final incoming = [for (final s in data['sites'] as List) Site.fromJson(s as Map)];
    final result = await store.merge(incoming);

    // Photo files this phone doesn't have yet, and the startup logs.
    var photos = 0;
    for (final s in store.allForMerge) {
      for (final v in s.visits) {
        for (final p in v.livePhotos) {
          final f = store.photoFile(s, p);
          if (f.existsSync()) continue;
          final entry = find('photos/${s.id}/${p.fileName}');
          if (entry == null) continue;
          await f.parent.create(recursive: true);
          await f.writeAsBytes(entry.content, flush: true);
          photos++;
        }
      }
    }
    final logs = await AppFiles.dir(LogRecorder.folder);
    for (final f in archive.files) {
      final i = f.name.indexOf('startup_logs/');
      if (!f.isFile || i < 0) continue;
      final out = File('${logs.path}/${f.name.substring(i + 'startup_logs/'.length)}');
      if (!out.existsSync()) await out.writeAsBytes(f.content, flush: true);
    }
    return ImportResult(result.added, result.updated, photos);
  } finally {
    await input.close();
  }
}
