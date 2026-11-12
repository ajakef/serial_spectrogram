import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'geo.dart';
import 'site_model.dart';

/// The phone's GPS. Works without cell service (the GPS needs only the sky).

/// Null if the app can use the location; otherwise what the user needs to do.
Future<String?> locationProblem() async {
  if (!await Geolocator.isLocationServiceEnabled()) return 'Turn on Location in the phone\'s quick settings.';
  var p = await Geolocator.checkPermission();
  if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
  if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
    return 'The app needs permission to use the phone\'s location: Settings, Apps, Aspen Plot, Permissions, Location.';
  }
  return null;
}

/// Positions about once a second, as precise as the phone can make them.
Stream<Position> positions() => Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        useMSLAltitude: true, // altitude above sea level (Android 14 and later)
      ),
    );

/// Shows a dialog that averages GPS fixes for up to [seconds] and returns the waypoint, or null if cancelled.
Future<Waypoint?> takeWaypoint(BuildContext context, {int seconds = 30}) =>
    showDialog<Waypoint>(context: context, barrierDismissible: false, builder: (_) => _WaypointDialog(seconds: seconds));

class _WaypointDialog extends StatefulWidget {
  const _WaypointDialog({required this.seconds});

  final int seconds;

  @override
  State<_WaypointDialog> createState() => _WaypointDialogState();
}

class _WaypointDialogState extends State<_WaypointDialog> {
  final average = FixAverager();
  StreamSubscription<Position>? _sub;
  Timer? _tick;
  int elapsed = 0;
  String? problem;
  double? lastAccuracy;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    problem = await locationProblem();
    if (!mounted) return;
    if (problem != null) {
      setState(() {});
      return;
    }
    _sub = positions().listen((p) {
      if (!mounted) return;
      setState(() {
        lastAccuracy = p.accuracy;
        if (p.accuracy <= 50) average.add(p.latitude, p.longitude, p.accuracy, altitude: p.altitude);
      });
    }, onError: (Object e) => setState(() => problem = 'GPS error: $e'));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => elapsed++);
      if (elapsed >= widget.seconds && average.count > 0) _save();
    });
  }

  void _save() {
    if (average.count == 0) return;
    _stop();
    Navigator.pop(
      context,
      Waypoint(
        lat: average.lat,
        lon: average.lon,
        altitude: average.altitude,
        accuracy: average.bestAccuracy,
        fixes: average.count,
        time: DateTime.now().toUtc(),
      ),
    );
  }

  void _stop() {
    _sub?.cancel();
    _tick?.cancel();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = problem ??
        (average.count == 0
            ? 'Waiting for GPS${lastAccuracy != null ? ' (accuracy so far ±${lastAccuracy!.round()} m)' : ''}...\n'
                'Stand still at the sensor, with a clear view of the sky.'
            : 'Averaging: ${average.count} fixes, best ±${average.bestAccuracy!.toStringAsFixed(1)} m.\n'
                'Hold still; saves in ${widget.seconds - elapsed > 0 ? widget.seconds - elapsed : 0} s.');
    return AlertDialog(
      title: const Text('Taking a waypoint'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (problem == null)
            LinearProgressIndicator(value: (elapsed / widget.seconds).clamp(0.0, 1.0)),
          const SizedBox(height: 12),
          Text(text),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (problem == null)
          FilledButton(onPressed: average.count > 0 ? _save : null, child: const Text('Save now')),
      ],
    );
  }
}
