import 'dart:math';

/// Distances, directions, and the compass heading, for the Sites tab's navigation screen. Plain Dart.

const _earthRadius = 6371008.8; // m, mean

double _rad(double deg) => deg * pi / 180;
double _deg(double rad) => rad * 180 / pi;

/// Great-circle distance in meters.
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = pow(sin(dLat / 2), 2) + cos(_rad(lat1)) * cos(_rad(lat2)) * pow(sin(dLon / 2), 2);
  return 2 * _earthRadius * asin(min(1.0, sqrt(a)));
}

/// Direction from point 1 toward point 2, in degrees clockwise from true north (0-360).
double bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
  final y = sin(_rad(lon2 - lon1)) * cos(_rad(lat2));
  final x = cos(_rad(lat1)) * sin(_rad(lat2)) - sin(_rad(lat1)) * cos(_rad(lat2)) * cos(_rad(lon2 - lon1));
  return (_deg(atan2(y, x)) + 360) % 360;
}

/// Which way the top of the phone points, in degrees clockwise from magnetic north (0-360), from the accelerometer
/// (gravity) and magnetometer readings in the phone's axes. Works with the phone flat or tilted toward you, not
/// upright. Null if the readings can't give a direction (e.g. in free fall, or next to a magnet). Same method as
/// Android's SensorManager.getRotationMatrix and getOrientation.
double? headingDegrees(double ax, double ay, double az, double mx, double my, double mz) {
  var hx = my * az - mz * ay;
  var hy = mz * ax - mx * az;
  var hz = mx * ay - my * ax;
  final normH = sqrt(hx * hx + hy * hy + hz * hz);
  final normA = sqrt(ax * ax + ay * ay + az * az);
  if (normH < 0.1 || normA < 0.1) return null;
  hx /= normH;
  hy /= normH;
  hz /= normH;
  final gx = ax / normA, gz = az / normA;
  final my2 = gz * hx - gx * hz; // y component of (gravity x east): north in the phone's axes
  return (_deg(atan2(hy, my2)) + 360) % 360;
}

/// Signed difference a - b in degrees, in -180..180.
double angleDifference(double a, double b) => ((a - b + 540) % 360) - 180;

/// Smooths a jittery angle (compass readings) without the jump at 0/360: averages its direction as a unit vector.
class AngleSmoother {
  AngleSmoother({this.weight = 0.15});

  final double weight; // of each new reading
  double? _s, _c;

  double? get value => _s == null ? null : (_deg(atan2(_s!, _c!)) + 360) % 360;

  double add(double degrees) {
    final s = sin(_rad(degrees)), c = cos(_rad(degrees));
    _s = _s == null ? s : _s! + weight * (s - _s!);
    _c = _c == null ? c : _c! + weight * (c - _c!);
    return value!;
  }
}

/// "12 m", "1.4 km".
String formatDistance(double m) {
  if (m < 1000) return '${m.round()} m';
  return '${(m / 1000).toStringAsFixed(m < 10000 ? 2 : 1)} km';
}

/// The average of several GPS fixes, each weighted by 1/accuracy² (better fixes count more).
class FixAverager {
  double _w = 0, _lat = 0, _lon = 0, _alt = 0, _wAlt = 0;
  int count = 0;
  double? bestAccuracy;

  void add(double lat, double lon, double accuracy, {double? altitude}) {
    final w = 1 / pow(max(accuracy, 1.0), 2);
    _w += w;
    _lat += w * lat;
    _lon += w * lon;
    if (altitude != null) {
      _alt += w * altitude;
      _wAlt += w;
    }
    count++;
    bestAccuracy = bestAccuracy == null ? accuracy : min(bestAccuracy!, accuracy);
  }

  double get lat => _lat / _w;
  double get lon => _lon / _w;
  double? get altitude => _wAlt == 0 ? null : _alt / _wAlt;
}
