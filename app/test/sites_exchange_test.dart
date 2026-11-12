import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:serial_spectrogram/app_files.dart';
import 'package:serial_spectrogram/sites/site_exchange.dart';
import 'package:serial_spectrogram/sites/site_model.dart';
import 'package:serial_spectrogram/sites/site_store.dart';

// Exporting sites from one phone and importing them on another.
void main() {
  late Directory phoneA, phoneB, tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sites_exchange_test');
    phoneA = Directory('${tmp.path}/a')..createSync();
    phoneB = Directory('${tmp.path}/b')..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<SiteStore> storeOn(Directory phone) async {
    AppFiles.testRoot = phone;
    final store = SiteStore();
    await store.load();
    return store;
  }

  String fakePhoto() {
    final f = File('${tmp.path}/camera.jpg');
    f.writeAsBytesSync(img.encodeJpg(img.Image(width: 400, height: 300)..clear(img.ColorRgb8(40, 120, 40))));
    return f.path;
  }

  test('export, then import on another phone', () async {
    final a = await storeOn(phoneA);
    final site = await a.newSite();
    site
      ..serialNumber = '2'
      ..network = 'XP'
      ..station = 'KIRK1'
      ..sampleRate = 400
      ..channels = ['', '', '', 'XYZ']
      ..waypoint = Waypoint(lat: 43.5, lon: -116.1, altitude: 820, accuracy: 4, fixes: 20, time: DateTime.utc(2026, 11, 12));
    await a.save(site, fields: true);
    final visit = Visit(time: DateTime.utc(2026, 11, 12, 8), kind: VisitKind.setup, notes: 'under the sagebrush, "north" side');
    site.visits.add(visit);
    final photo = await a.addPhoto(site, visit, fakePhoto());
    photo.markers.add(Marker(x: 0.25, y: 0.5, label: 'Seismic 1'));
    await a.savePhoto(site, photo);

    final zip = await exportSites(a, a.sites);
    final archive = ZipDecoder().decodeStream(InputFileStream(zip.path));
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, containsAll(['README.txt', 'sites.csv', 'visits.csv', 'photos.csv', 'sites.kml', 'sites.json',
        'photos/${site.id}/${photo.id}.jpg', 'photos_marked/KIRK1_20261112_1.jpg']));
    final csv = utf8.decode(archive.findFile('sites.csv')!.content).split('\n');
    expect(csv[1], startsWith('${site.id},2,XP,KIRK1,,CDF,DHZ,DHN,XYZ,400,43.5000000,-116.1000000,820.0,4.0,20,'));
    expect(utf8.decode(archive.findFile('visits.csv')!.content), contains('"under the sagebrush, ""north"" side"'));
    expect(utf8.decode(archive.findFile('photos.csv')!.content), contains('Seismic 1 (0.250, 0.500)'));
    expect(utf8.decode(archive.findFile('sites.kml')!.content), contains('<coordinates>-116.1,43.5,820.0</coordinates>'));
    final marked = img.decodeJpg(archive.findFile('photos_marked/KIRK1_20261112_1.jpg')!.content)!;
    final p = marked.getPixel(100, 150 - 8); // on the ring around the marker (radius 8 on this small photo)
    expect(p.r, greaterThan(200)); // yellow
    expect(p.b, lessThan(100));

    final b = await storeOn(phoneB);
    final result = await importSites(b, zip.path);
    expect((result.added, result.updated, result.photos), (1, 0, 1));
    expect(b.sites.single.station, 'KIRK1');
    expect(b.photoFile(b.sites.single, b.sites.single.visits.single.photos.single).existsSync(), isTrue);

    // importing the same file again changes nothing
    final again = await importSites(b, zip.path);
    expect((again.added, again.updated, again.photos), (0, 0, 0));

    // and phone B's data survive reloading
    final reloaded = await storeOn(phoneB);
    expect(reloaded.sites.single.visits.single.photos.single.markers.single.label, 'Seismic 1');
  });

  test('a file that isn\'t an export is refused with a plain message', () async {
    final b = await storeOn(phoneB);
    final notZip = File('${tmp.path}/x.zip')..writeAsStringSync('hello');
    expect(() => importSites(b, notZip.path), throwsA(isA<FormatException>()));
  });
}
