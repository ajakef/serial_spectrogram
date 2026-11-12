import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../check_session.dart';
import 'geo.dart';
import 'location.dart';
import 'marked_photo.dart';
import 'phone.dart';
import 'site_model.dart';
import 'site_store.dart';
import 'visit_screen.dart';

/// Finding a site again: an arrow and the distance to its waypoint, with its photos below to find the hidden sensors
/// once close. Tap a photo to make it big or small; tap a big one's picture to see it full screen.
class NavigateScreen extends StatefulWidget {
  const NavigateScreen({
    super.key,
    required this.store,
    required this.site,
    required this.check,
    this.testPositions,
    this.testHeadings,
  });

  final SiteStore store;
  final Site site;
  final CheckSession check;
  final Stream<Position>? testPositions; // tests: pretend GPS fixes instead of the phone's
  final Stream<double>? testHeadings; // tests: pretend compass headings (degrees from magnetic north)

  @override
  State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen> {
  Position? here;
  String? problem;
  double? declination; // degrees east: added to the magnetic heading to get the true heading
  final heading = AngleSmoother(weight: 0.1);
  final _compassTick = ValueNotifier<int>(0); // redraws just the arrow at the compass's rate
  bool compassWorks = true;
  AccelerometerEvent? _accel;
  final _subs = <StreamSubscription>[];
  late List<(Visit, SitePhoto)> photos;
  final big = <String>{}; // ids of the photos shown big

  Site get site => widget.site;

  @override
  void initState() {
    super.initState();
    // The arrow assumes the phone is upright in portrait, so keep the screen from turning sideways here.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _loadPhotos();
    // Start with the newest photo that marks hidden sensors (else the newest photo) shown big.
    final marked = photos.where((x) => x.$2.markers.isNotEmpty);
    if (photos.isNotEmpty) big.add((marked.isNotEmpty ? marked.first : photos.first).$2.id);
    _startLocation();
    _startCompass();
  }

  void _loadPhotos() {
    photos = [for (final v in site.visitsNewestFirst) for (final p in v.livePhotos) (v, p)];
  }

  Future<void> _startLocation() async {
    problem = widget.testPositions != null ? null : await locationProblem();
    if (!mounted) return;
    if (problem != null) {
      setState(() {});
      return;
    }
    _subs.add((widget.testPositions ?? positions()).listen((p) {
      if (!mounted) return;
      setState(() => here = p);
      if (declination == null) {
        Phone.declination(p.latitude, p.longitude, p.altitude).then((d) {
          if (mounted && d != null) setState(() => declination = d);
        });
      }
    }, onError: (Object e) {
      if (mounted) setState(() => problem = 'GPS error: $e');
    }));
  }

  void _startCompass() {
    if (widget.testHeadings != null) {
      _subs.add(widget.testHeadings!.listen((h) {
        heading.add(h);
        _compassTick.value++;
      }));
      return;
    }
    void noCompass(Object _) {
      if (mounted) setState(() => compassWorks = false);
    }

    _subs.add(accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) => _accel = e, onError: noCompass));
    _subs.add(magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((m) {
      final a = _accel;
      if (a == null) return;
      final h = headingDegrees(a.x, a.y, a.z, m.x, m.y, m.z);
      if (h == null) return;
      heading.add(h);
      _compassTick.value++;
    }, onError: noCompass));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    SystemChrome.setPreferredOrientations([]); // back to turning with the phone
    _compassTick.dispose();
    super.dispose();
  }

  Future<void> _addVisit() async {
    await addVisitAndOpen(context, widget.store, site, widget.check);
    if (!mounted) return;
    setState(_loadPhotos);
  }

  @override
  Widget build(BuildContext context) {
    final bigOnes = photos.where((x) => big.contains(x.$2.id)).toList();
    final smallOnes = photos.where((x) => !big.contains(x.$2.id)).toList();
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(
        title: Text('To ${site.title}'),
        actions: [
          TextButton.icon(icon: const Icon(Icons.add_a_photo), label: const Text('Add visit'), onPressed: _addVisit),
        ],
      ),
      body: Column(
        children: [
          SizedBox(height: 190, child: _pointer()),
          const Divider(height: 1),
          Expanded(
            child: photos.isEmpty
                ? const Center(child: Text('No photos of this site yet.'))
                : bigOnes.isEmpty
                    ? const Center(child: Text('Tap a photo below to make it big.'))
                    : ListView(
                        children: [
                          for (final (v, p) in bigOnes)
                            Column(
                              children: [
                                ListTile(
                                  dense: true,
                                  title: Text('${v.kind.label}, ${v.time.toLocal().toString().substring(0, 10)}'
                                      '${p.markers.isEmpty ? '' : ': ${p.markers.map((m) => m.label).join(', ')}'}'),
                                  trailing: IconButton(
                                    tooltip: 'Make small',
                                    icon: const Icon(Icons.close_fullscreen),
                                    onPressed: () => setState(() => big.remove(p.id)),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => Navigator.push(context, MaterialPageRoute<void>(
                                      builder: (_) => _FullScreenPhoto(store: widget.store, site: site, photo: p))),
                                  child: SizedBox(
                                    height: width * 0.8,
                                    child: MarkedPhoto(file: widget.store.photoFile(site, p), markers: p.markers, cacheWidth: 1200),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
          ),
          if (smallOnes.isNotEmpty)
            Container(
              height: 96,
              color: Colors.black12,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(4),
                children: [
                  for (final (_, p) in smallOnes)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: GestureDetector(
                        onTap: () => setState(() => big.add(p.id)),
                        child: SizedBox(
                          width: 88,
                          child: MarkedPhoto(
                            file: widget.store.photoFile(site, p),
                            markers: p.markers,
                            cacheWidth: 200,
                            showLabels: false,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _pointer() {
    final w = site.waypoint!;
    final p = here;
    if (problem != null) return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(problem!)));
    if (p == null) return const Center(child: Text('Waiting for GPS...'));
    final d = distanceMeters(p.latitude, p.longitude, w.lat, w.lon);
    final bearing = bearingDegrees(p.latitude, p.longitude, w.lat, w.lon);
    final close = d <= max(8.0, 1.5 * p.accuracy);
    return ValueListenableBuilder<int>(
      valueListenable: _compassTick,
      builder: (context, _, _) {
        final h = compassWorks ? heading.value : null;
        final turn = h == null ? null : angleDifference(bearing, h + (declination ?? 0));
        final String direction;
        if (close) {
          direction = 'You\'re within about ${max(d, p.accuracy).round()} m. Look for the markers in the photos.';
        } else if (turn == null) {
          direction = 'No compass: head ${bearing.round()}° from north.';
        } else if (turn.abs() < 15) {
          direction = 'Straight ahead';
        } else {
          direction = turn > 0 ? 'Turn right ${turn.round()}°' : 'Turn left ${(-turn).round()}°';
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: 150,
                height: 150,
                child: CustomPaint(painter: _ArrowPainter(close ? null : (turn ?? bearing), close: close, northUp: turn == null)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatDistance(d), style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w600)),
                    Text('GPS ±${p.accuracy.round()} m${w.accuracy != null ? ', waypoint ±${w.accuracy!.round()} m' : ''}',
                        style: const TextStyle(color: Colors.black54)),
                    const SizedBox(height: 6),
                    Text(direction, style: const TextStyle(fontSize: 16)),
                    if (!close && turn != null)
                      const Text('Arrow wrong? Wave the phone in a figure-8, away from cars and metal.',
                          style: TextStyle(fontSize: 11, color: Colors.black45)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A big arrow turned [degrees] clockwise from straight up (or from north, with an N, if [northUp]); a target when
/// [close].
class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.degrees, {required this.close, required this.northUp});

  final double? degrees;
  final bool close;
  final bool northUp;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = min(size.width, size.height) / 2 - 4;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.black12;
    canvas.drawCircle(c, r, ring);
    if (close || degrees == null) {
      final target = Paint()..color = Colors.green.shade700;
      canvas.drawCircle(c, r * 0.55, target..style = PaintingStyle.stroke..strokeWidth = 6);
      canvas.drawCircle(c, r * 0.18, target..style = PaintingStyle.fill);
      return;
    }
    if (northUp) {
      final tp = TextPainter(
        text: const TextSpan(text: 'N', style: TextStyle(color: Colors.black54, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - r + 2));
    }
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(degrees! * pi / 180);
    final arrow = Path()
      ..moveTo(0, -r * 0.85)
      ..lineTo(r * 0.5, r * 0.55)
      ..lineTo(0, r * 0.3)
      ..lineTo(-r * 0.5, r * 0.55)
      ..close();
    canvas.drawPath(arrow, Paint()..color = northUp ? Colors.blueGrey : Colors.blue.shade700);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.degrees != degrees || old.close != close || old.northUp != northUp;
}

class _FullScreenPhoto extends StatelessWidget {
  const _FullScreenPhoto({required this.store, required this.site, required this.photo});

  final SiteStore store;
  final Site site;
  final SitePhoto photo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: InteractiveViewer(
        maxScale: 6,
        child: MarkedPhoto(file: store.photoFile(site, photo), markers: photo.markers),
      ),
    );
  }
}
