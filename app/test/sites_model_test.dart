import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/sites/geo.dart';
import 'package:serial_spectrogram/sites/site_model.dart';

void main() {
  group('geography', () {
    test('distance and bearing', () {
      // 1 degree of latitude is about 111.2 km
      expect(distanceMeters(43.0, -116.0, 44.0, -116.0), closeTo(111195, 10));
      expect(bearingDegrees(43.0, -116.0, 44.0, -116.0), closeTo(0, 1e-9));
      expect(bearingDegrees(43.0, -116.0, 43.0, -115.99), closeTo(90, 0.01));
      expect(bearingDegrees(43.0, -116.0, 42.99, -116.0), closeTo(180, 1e-9));
      expect(distanceMeters(43.0, -116.0, 43.0001, -116.0), closeTo(11.1, 0.1));
    });

    test('compass heading from gravity and the magnetic field (phone flat, screen up)', () {
      // Field points north and down (northern hemisphere). Top of the phone toward north:
      expect(headingDegrees(0, 0, 9.8, 0, 20, -40), closeTo(0, 1e-9));
      // toward east: north is to the phone's left (-x)
      expect(headingDegrees(0, 0, 9.8, -20, 0, -40), closeTo(90, 1e-9));
      // toward south-west
      expect(headingDegrees(0, 0, 9.8, 14.14, -14.14, -40), closeTo(225, 0.01));
      // tilted 45 degrees toward the user, still facing north: same heading
      // (top edge raised: gravity's reaction has +y and +z parts; the field's north part splits the same way)
      expect(headingDegrees(0, 6.93, 6.93, 0, 20 * 0.707 - 40 * 0.707, -20 * 0.707 - 40 * 0.707), closeTo(0, 0.01));
      // ... and facing east
      expect(headingDegrees(0, 6.93, 6.93, -20, -40 * 0.707, -40 * 0.707), closeTo(90, 0.01));
      expect(headingDegrees(0, 0, 0, 0, 20, -40), isNull);
    });

    test('angle smoothing crosses north without jumping', () {
      final s = AngleSmoother(weight: 0.5);
      s.add(350);
      expect(s.add(10), anyOf(closeTo(0, 0.01), closeTo(360, 0.01)));
      expect(angleDifference(10, 350), closeTo(20, 1e-9));
      expect(angleDifference(350, 10), closeTo(-20, 1e-9));
    });

    test('fix averaging weights the better fixes', () {
      final a = FixAverager()
        ..add(43.0, -116.0, 3, altitude: 800)
        ..add(43.001, -116.0, 30, altitude: 900);
      expect(a.lat, closeTo(43.00001, 0.00001));
      expect(a.altitude, closeTo(801, 1));
      expect(a.bestAccuracy, 3);
      expect(a.count, 2);
    });

    test('distances read naturally', () {
      expect(formatDistance(12.4), '12 m');
      expect(formatDistance(1430), '1.43 km');
      expect(formatDistance(25300), '25.3 km');
    });
  });

  group('sites', () {
    Site example() => Site(serialNumber: '2', station: 'KIRK1', network: 'XP', channels: ['', 'DHZ', '', ''])
      ..waypoint = Waypoint(lat: 43.5, lon: -116.1, altitude: 820, accuracy: 4, fixes: 20, time: DateTime.utc(2026, 11, 12))
      ..visits.add(Visit(time: DateTime.utc(2026, 11, 12, 8), kind: VisitKind.setup, notes: 'under the sagebrush')
        ..photos.add(SitePhoto(taken: DateTime.utc(2026, 11, 12, 8, 5), markers: [Marker(x: 0.4, y: 0.6, label: 'Seismic 1')])));

    test('round trip through JSON', () {
      final s = example();
      final back = Site.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map);
      expect(jsonEncode(back.toJson()), jsonEncode(s.toJson()));
      expect(back.visits.single.photos.single.markers.single.label, 'Seismic 1');
      expect(back.timeOf(VisitKind.setup), DateTime.utc(2026, 11, 12, 8));
      expect(back.timeOf(VisitKind.pickup), isNull);
    });

    test('merging copies from two phones keeps everything, newest edits winning', () {
      final a = example();
      final b = Site.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map);
      final later = a.updated.add(const Duration(minutes: 5));
      // phone B: a return visit with a photo, and a corrected station code
      b
        ..station = 'KIRK2'
        ..updated = later
        ..visits.add(Visit(time: DateTime.utc(2026, 12, 1), notes: 'battery swapped', updated: later));
      // phone A: a marker added to the setup photo, later than B's copy of it
      a.visits.first.photos.first
        ..markers.add(Marker(x: 0.1, y: 0.1, label: 'Logger'))
        ..updated = later;
      // phone A also deleted nothing; phone B deleted no photo
      final mine = [a];
      final result = mergeSites(mine, [b, Site(station: 'NEW')]);
      expect(result, (added: 1, updated: 1));
      expect(a.station, 'KIRK2');
      expect(a.liveVisits.length, 2);
      expect(a.visits.first.photos.first.markers.length, 2);
      // merging again changes nothing
      expect(mergeSites(mine, [b]), (added: 0, updated: 0));
    });

    test('a deletion survives merging an older copy', () {
      final a = example();
      final old = Site.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map);
      a.visits.first
        ..deleted = true
        ..updated = a.visits.first.updated.add(const Duration(seconds: 1));
      mergeSite(a, old);
      expect(a.liveVisits, isEmpty);
    });
  });
}
