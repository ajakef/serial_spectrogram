import 'dart:math';

/// The Sites tab's records: a site (a logger's location and codes), its visits (setup, service, pickup), and each
/// visit's photos with markers. Plain Dart, stored as JSON.
///
/// Every record has a random id and an `updated` time, so copies from several phones can be merged (see [mergeSites]):
/// records are matched by id, and the one changed last wins. Deleting a record keeps it with `deleted` set, so that
/// merging an older copy doesn't bring it back.

final _random = Random.secure();

/// A new random id: 16 hex digits.
String newId() => List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

DateTime? _time(Object? s) => s is String ? DateTime.tryParse(s)?.toUtc() : null;
String _iso(DateTime t) => t.toUtc().toIso8601String();

class Waypoint {
  Waypoint({required this.lat, required this.lon, this.altitude, this.accuracy, this.fixes = 1, required this.time});

  final double lat;
  final double lon;
  final double? altitude; // m (GPS altitude; above sea level on Android 14 and later)
  final double? accuracy; // m, horizontal, as the phone estimates it
  final int fixes; // GPS fixes averaged
  final DateTime time;

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        'altitude': altitude,
        'accuracy': accuracy,
        'fixes': fixes,
        'time': _iso(time),
      };

  static Waypoint? fromJson(Object? j) {
    if (j is! Map) return null;
    return Waypoint(
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      altitude: (j['altitude'] as num?)?.toDouble(),
      accuracy: (j['accuracy'] as num?)?.toDouble(),
      fixes: (j['fixes'] as num?)?.toInt() ?? 1,
      time: _time(j['time']) ?? DateTime.now().toUtc(),
    );
  }
}

/// A spot marked on a photo, e.g. "Seismic 2". x and y are fractions (0-1) of the photo's width and height.
class Marker {
  Marker({required this.x, required this.y, required this.label});

  double x;
  double y;
  String label;

  static const kinds = ['Logger', 'Seismic', 'Infrasound', 'Battery'];

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'label': label};

  static Marker fromJson(Map j) =>
      Marker(x: (j['x'] as num).toDouble(), y: (j['y'] as num).toDouble(), label: j['label'] as String? ?? '');
}

class SitePhoto {
  SitePhoto({String? id, required this.taken, List<Marker>? markers, DateTime? updated, this.deleted = false})
      : id = id ?? newId(),
        markers = markers ?? [],
        updated = updated ?? DateTime.now().toUtc();

  final String id;
  final DateTime taken;
  final List<Marker> markers;
  DateTime updated;
  bool deleted;

  /// File name in the site's photos folder.
  String get fileName => '$id.jpg';

  Map<String, dynamic> toJson() => {
        'id': id,
        'taken': _iso(taken),
        'markers': [for (final m in markers) m.toJson()],
        'updated': _iso(updated),
        if (deleted) 'deleted': true,
      };

  static SitePhoto fromJson(Map j) => SitePhoto(
        id: j['id'] as String,
        taken: _time(j['taken']) ?? DateTime.now().toUtc(),
        markers: [for (final m in (j['markers'] as List? ?? const [])) Marker.fromJson(m as Map)],
        updated: _time(j['updated']),
        deleted: j['deleted'] == true,
      );
}

enum VisitKind {
  setup('Setup'),
  service('Service'),
  pickup('Pickup');

  const VisitKind(this.label);
  final String label;

  static VisitKind parse(Object? s) => VisitKind.values.firstWhere((k) => k.name == s, orElse: () => VisitKind.service);
}

class Visit {
  Visit({
    String? id,
    required this.time,
    this.kind = VisitKind.service,
    this.notes = '',
    List<SitePhoto>? photos,
    this.startupLog,
    DateTime? updated,
    this.deleted = false,
  })  : id = id ?? newId(),
        photos = photos ?? [],
        updated = updated ?? DateTime.now().toUtc();

  final String id;
  DateTime time;
  VisitKind kind;
  String notes;
  final List<SitePhoto> photos;
  String? startupLog; // file name of the Check tab's log from this visit, if any
  DateTime updated;
  bool deleted;

  Iterable<SitePhoto> get livePhotos => photos.where((p) => !p.deleted);

  Map<String, dynamic> toJson() => {
        'id': id,
        'time': _iso(time),
        'kind': kind.name,
        'notes': notes,
        'photos': [for (final p in photos) p.toJson()],
        if (startupLog != null) 'startupLog': startupLog,
        'updated': _iso(updated),
        if (deleted) 'deleted': true,
      };

  static Visit fromJson(Map j) => Visit(
        id: j['id'] as String,
        time: _time(j['time']) ?? DateTime.now().toUtc(),
        kind: VisitKind.parse(j['kind']),
        notes: j['notes'] as String? ?? '',
        photos: [for (final p in (j['photos'] as List? ?? const [])) SitePhoto.fromJson(p as Map)],
        startupLog: j['startupLog'] as String?,
        updated: _time(j['updated']),
        deleted: j['deleted'] == true,
      );
}

class Site {
  Site({
    String? id,
    DateTime? created,
    DateTime? updated,
    this.serialNumber = '',
    this.network = '',
    this.station = '',
    this.location = '',
    List<String>? channels,
    this.sampleRate,
    this.waypoint,
    List<Visit>? visits,
    this.deleted = false,
  })  : id = id ?? newId(),
        created = created ?? DateTime.now().toUtc(),
        updated = updated ?? DateTime.now().toUtc(),
        channels = channels ?? ['', '', '', ''],
        visits = visits ?? [];

  final String id;
  final DateTime created;
  DateTime updated; // of the site's own fields (visits and photos have their own)
  String serialNumber;
  String network;
  String station;
  String location;
  List<String> channels; // '' means the default for the sample rate
  int? sampleRate; // from the logger, when filled in from the Check tab
  Waypoint? waypoint;
  final List<Visit> visits;
  bool deleted;

  Iterable<Visit> get liveVisits => visits.where((v) => !v.deleted);

  /// Visits, newest first.
  List<Visit> get visitsNewestFirst => liveVisits.toList()..sort((a, b) => b.time.compareTo(a.time));

  /// What to call the site in lists: its station code, else the serial number.
  String get title => station.isNotEmpty ? station : (serialNumber.isNotEmpty ? 'SN $serialNumber' : 'New site');

  /// The latest time anything in the site changed (for sorting and merging).
  DateTime get lastChange {
    var t = updated;
    for (final v in visits) {
      if (v.updated.isAfter(t)) t = v.updated;
      for (final p in v.photos) {
        if (p.updated.isAfter(t)) t = p.updated;
      }
    }
    return t;
  }

  DateTime? timeOf(VisitKind kind) {
    final v = liveVisits.where((v) => v.kind == kind).toList()..sort((a, b) => a.time.compareTo(b.time));
    if (v.isEmpty) return null;
    return kind == VisitKind.pickup ? v.last.time : v.first.time;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'created': _iso(created),
        'updated': _iso(updated),
        'serialNumber': serialNumber,
        'network': network,
        'station': station,
        'location': location,
        'channels': channels,
        'sampleRate': sampleRate,
        'waypoint': waypoint?.toJson(),
        'visits': [for (final v in visits) v.toJson()],
        if (deleted) 'deleted': true,
      };

  static Site fromJson(Map j) => Site(
        id: j['id'] as String,
        created: _time(j['created']),
        updated: _time(j['updated']),
        serialNumber: j['serialNumber']?.toString() ?? '',
        network: j['network'] as String? ?? '',
        station: j['station'] as String? ?? '',
        location: j['location'] as String? ?? '',
        channels: [for (final c in (j['channels'] as List? ?? const ['', '', '', ''])) c as String],
        sampleRate: (j['sampleRate'] as num?)?.toInt(),
        waypoint: Waypoint.fromJson(j['waypoint']),
        visits: [for (final v in (j['visits'] as List? ?? const [])) Visit.fromJson(v as Map)],
        deleted: j['deleted'] == true,
      );
}

/// Merges another copy of a site (same id) into [mine], keeping the newer version of each record. Returns whether
/// anything changed.
bool mergeSite(Site mine, Site other) {
  var changed = false;
  if (other.updated.isAfter(mine.updated)) {
    mine
      ..updated = other.updated
      ..serialNumber = other.serialNumber
      ..network = other.network
      ..station = other.station
      ..location = other.location
      ..channels = List.of(other.channels)
      ..sampleRate = other.sampleRate
      ..waypoint = other.waypoint
      ..deleted = other.deleted;
    changed = true;
  }
  for (final ov in other.visits) {
    final i = mine.visits.indexWhere((v) => v.id == ov.id);
    if (i < 0) {
      mine.visits.add(ov);
      changed = true;
      continue;
    }
    final mv = mine.visits[i];
    if (ov.updated.isAfter(mv.updated)) {
      mv
        ..time = ov.time
        ..kind = ov.kind
        ..notes = ov.notes
        ..startupLog = ov.startupLog
        ..updated = ov.updated
        ..deleted = ov.deleted;
      changed = true;
    }
    for (final op in ov.photos) {
      final k = mv.photos.indexWhere((p) => p.id == op.id);
      if (k < 0) {
        mv.photos.add(op);
        changed = true;
      } else if (op.updated.isAfter(mv.photos[k].updated)) {
        mv.photos[k] = op;
        changed = true;
      }
    }
  }
  return changed;
}

/// Merges [incoming] sites into [mine] (matched by id). Returns the counts of sites added and updated.
({int added, int updated}) mergeSites(List<Site> mine, Iterable<Site> incoming) {
  var added = 0, updated = 0;
  for (final s in incoming) {
    final i = mine.indexWhere((m) => m.id == s.id);
    if (i < 0) {
      mine.add(s);
      added++;
    } else if (mergeSite(mine[i], s)) {
      updated++;
    }
  }
  return (added: added, updated: updated);
}
