import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:serial_spectrogram/boot_report.dart';
import 'package:serial_spectrogram/check_session.dart';
import 'package:serial_spectrogram/serial_link.dart';
import 'package:serial_spectrogram/sites/navigate_screen.dart';
import 'package:serial_spectrogram/sites/site_model.dart';
import 'package:serial_spectrogram/sites/site_screen.dart';
import 'package:serial_spectrogram/sites/site_store.dart';

Position _at(double lat, double lon, double accuracy) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.now(),
      accuracy: accuracy,
      altitude: 800,
      altitudeAccuracy: 5,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

// Stream events arrive between frames: draw one more frame to show them.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('navigation: arrow, distance, and "close" once there', (tester) async {
    final site = Site(station: 'KIRK1')..waypoint = Waypoint(lat: 43.5, lon: -116.1, time: DateTime.utc(2026));
    final positions = StreamController<Position>();
    final headings = StreamController<double>();
    await tester.pumpWidget(MaterialApp(
      home: NavigateScreen(
        store: SiteStore(),
        site: site,
        check: CheckSession(SerialLink()),
        testPositions: positions.stream,
        testHeadings: headings.stream,
      ),
    ));
    await tester.pump();
    expect(find.text('Waiting for GPS...'), findsOneWidget);

    positions.add(_at(43.5 - 0.00045, -116.1, 4)); // 50 m south of the site
    headings.add(0); // facing north
    await _frames(tester);
    expect(find.text('50 m'), findsOneWidget);
    expect(find.text('Straight ahead'), findsOneWidget);

    for (var i = 0; i < 100; i++) {
      headings.add(90); // now facing east (the arrow is smoothed, so it takes a moment)
    }
    await _frames(tester);
    expect(find.text('Turn left 90°'), findsOneWidget);

    positions.add(_at(43.5, -116.1, 4)); // arrived
    await _frames(tester);
    expect(find.textContaining('You\'re within about 4 m'), findsOneWidget);
    expect(find.text('No photos of this site yet.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // leave the screen (it stops listening)
    unawaited(positions.close());
    unawaited(headings.close());
  });

  test('a new site takes the logger\'s serial number and codes as it records them', () {
    final s = LoggerSettings.parse('Config: gains 128,0,0,0; 400 sps; gps_mode 1, cycle 30 min, quota 20; '
        'SEED codes XP.00002..CDF.DHZ.DHN.DHE')!;
    final site = Site();
    fillSiteFromLogger(site, 2, s);
    expect(site.serialNumber, '2');
    expect(site.network, 'XP');
    expect(site.station, '00002');
    expect(site.sampleRate, 400);
    expect(site.channels, ['CDF', '', '', '']); // channels that are off are left blank
  });
}
