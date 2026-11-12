import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_files.dart';
import 'site_model.dart';

/// The sites saved on this phone: `sites/<site id>/site.json`, with the site's photos in `sites/<site id>/photos/`.
class SiteStore extends ChangeNotifier {
  final List<Site> _all = []; // including deleted ones (kept so merges don't bring them back)
  String? _base;
  bool loaded = false;

  /// The sites, by name.
  List<Site> get sites => _all.where((s) => !s.deleted).toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  /// Every site including deleted ones, for merging.
  List<Site> get allForMerge => _all;

  Future<void> load() async {
    if (loaded) return;
    final dir = await AppFiles.dir('sites');
    _base = dir.path;
    for (final d in dir.listSync().whereType<Directory>()) {
      final f = File('${d.path}/site.json');
      if (!f.existsSync()) continue;
      try {
        _all.add(Site.fromJson(jsonDecode(await f.readAsString()) as Map));
      } catch (e) {
        debugPrint('Skipping unreadable ${f.path}: $e');
      }
    }
    loaded = true;
    notifyListeners();
  }

  /// The file holding a photo (it may not exist yet, e.g. for a photo whose file another phone didn't send).
  File photoFile(Site s, SitePhoto p) => File('$_base/${s.id}/photos/${p.fileName}');

  Future<Site> newSite() async {
    final s = Site();
    _all.add(s);
    await save(s);
    return s;
  }

  /// Saves a site after changes. Set [fields] when the site's own fields changed (serial number, codes, waypoint).
  Future<void> save(Site s, {bool fields = false}) async {
    if (fields) s.updated = DateTime.now().toUtc();
    final dir = Directory('$_base/${s.id}');
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/site.json.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(s.toJson()), flush: true);
    await tmp.rename('${dir.path}/site.json'); // replaces the old file in one step
    notifyListeners();
  }

  /// Saves after a visit's notes, kind, or time changed.
  Future<void> saveVisit(Site s, Visit v) {
    v.updated = DateTime.now().toUtc();
    return save(s);
  }

  /// Saves after a photo's markers changed.
  Future<void> savePhoto(Site s, SitePhoto p) {
    p.updated = DateTime.now().toUtc();
    return save(s);
  }

  /// Adds a photo (from the camera, in a temporary file) to a visit.
  Future<SitePhoto> addPhoto(Site s, Visit v, String sourcePath) async {
    final p = SitePhoto(taken: DateTime.now().toUtc());
    final f = photoFile(s, p);
    await f.parent.create(recursive: true);
    await File(sourcePath).copy(f.path);
    v.photos.add(p);
    await saveVisit(s, v);
    return p;
  }

  Future<void> deletePhoto(Site s, SitePhoto p) async {
    p
      ..deleted = true
      ..updated = DateTime.now().toUtc();
    final f = photoFile(s, p);
    if (f.existsSync()) await f.delete();
    await save(s);
  }

  Future<void> deleteVisit(Site s, Visit v) async {
    for (final p in v.livePhotos.toList()) {
      final f = photoFile(s, p);
      if (f.existsSync()) await f.delete();
    }
    v
      ..deleted = true
      ..updated = DateTime.now().toUtc();
    await save(s);
  }

  Future<void> deleteSite(Site s) async {
    final photos = Directory('$_base/${s.id}/photos');
    if (photos.existsSync()) await photos.delete(recursive: true);
    s.deleted = true;
    await save(s, fields: true);
  }

  /// Merges sites from another phone's export. Returns the counts of sites added and updated.
  Future<({int added, int updated})> merge(List<Site> incoming) async {
    final before = {for (final s in _all) s.id: jsonEncode(s.toJson())};
    final result = mergeSites(_all, incoming);
    for (final s in _all) {
      if (before[s.id] != jsonEncode(s.toJson())) await save(s);
    }
    notifyListeners();
    return result;
  }
}
