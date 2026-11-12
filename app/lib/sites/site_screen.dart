import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../boot_report.dart';
import '../check_session.dart';
import 'geo.dart';
import 'location.dart';
import 'navigate_screen.dart';
import 'site_model.dart';
import 'site_store.dart';
import 'visit_screen.dart';

/// One site: the logger's serial number and SEED codes, the waypoint, and the visits.
class SiteScreen extends StatefulWidget {
  const SiteScreen({super.key, required this.store, required this.site, required this.check});

  final SiteStore store;
  final Site site;
  final CheckSession check;

  @override
  State<SiteScreen> createState() => _SiteScreenState();
}

class _SiteScreenState extends State<SiteScreen> {
  Site get site => widget.site;
  Timer? _saveFields;
  int _formVersion = 0; // changes when the fields are filled in from the logger, to rebuild them

  @override
  void dispose() {
    if (_saveFields?.isActive ?? false) {
      _saveFields!.cancel();
      unawaited(widget.store.save(site, fields: true));
    }
    super.dispose();
  }

  void _fieldsChanged() {
    setState(() {});
    _saveFields?.cancel();
    _saveFields = Timer(const Duration(seconds: 1), () => widget.store.save(site, fields: true));
  }

  /// The logger's serial number and codes, if one is plugged in (Check tab) and has reported them.
  ({int serial, LoggerSettings settings})? get _logger {
    final r = widget.check.report;
    if (r.serialNumber == null || r.settings == null) return null;
    return (serial: r.serialNumber!, settings: r.settings!);
  }

  void _fillFromLogger() {
    final l = _logger!;
    setState(() {
      fillSiteFromLogger(site, l.serial, l.settings);
      _formVersion++;
    });
    unawaited(widget.store.save(site, fields: true));
  }

  /// Differences between this site's codes and what the plugged-in logger with the same serial number records.
  List<String> _mismatches() {
    final l = _logger;
    if (l == null || site.serialNumber != '${l.serial}') return const [];
    final s = l.settings;
    return [
      if (site.network != s.network) 'network: here "${site.network}", logger "${s.network}"',
      if (site.station != s.station) 'station: here "${site.station}", logger "${s.station}"',
      if (site.location != s.location) 'location: here "${site.location}", logger "${s.location}"',
      for (var i = 0; i < 4; i++)
        if (s.gains[i] > 0 && site.channels[i].isNotEmpty && site.channels[i] != s.channels[i])
          'channel ${i + 1}: here ${site.channels[i]}, logger ${s.channels[i]}',
    ];
  }

  Future<void> _takeWaypoint() async {
    final w = await takeWaypoint(context);
    if (w == null) return;
    setState(() => site.waypoint = w);
    await widget.store.save(site, fields: true);
  }

  Future<void> _addVisit() async {
    await addVisitAndOpen(context, widget.store, site, widget.check);
    if (mounted) setState(() {});
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${site.title}?'),
        content: const Text('Its waypoint, visits, notes, and photos will be deleted from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    _saveFields?.cancel();
    await widget.store.deleteSite(site);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final w = site.waypoint;
    final logger = _logger;
    final mismatches = _mismatches();
    final visits = site.visitsNewestFirst;
    return Scaffold(
      appBar: AppBar(
        title: Text(site.title),
        actions: [IconButton(tooltip: 'Delete site', icon: const Icon(Icons.delete_outline), onPressed: _delete)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (mismatches.isNotEmpty)
            Card(
              color: Colors.orange.shade50,
              child: ListTile(
                leading: Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
                title: Text('Logger ${logger!.serial} is recording different codes'),
                subtitle: Text(mismatches.join('\n')),
                trailing: TextButton(onPressed: _fillFromLogger, child: const Text('Use the logger\'s')),
              ),
            ),
          _heading('Logger'),
          if (logger != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.usb),
                label: Text('Fill in from logger ${logger.serial} (Check tab)'),
                onPressed: _fillFromLogger,
              ),
            ),
          ..._fields(),
          _heading('Waypoint'),
          if (w == null) const Text('None yet. Stand at the sensors and take one.'),
          if (w != null) ...[
            Text('${w.lat.toStringAsFixed(6)}, ${w.lon.toStringAsFixed(6)}'),
            Text(
              [
                if (w.accuracy != null) '±${w.accuracy!.toStringAsFixed(1)} m',
                if (w.altitude != null) 'altitude ${w.altitude!.round()} m',
                '${w.fixes} fix${w.fixes == 1 ? '' : 'es'}',
                w.time.toLocal().toString().substring(0, 16),
              ].join(' · '),
              style: const TextStyle(color: Colors.black54),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.my_location),
                label: Text(w == null ? 'Take waypoint' : 'Take again'),
                onPressed: _takeWaypoint,
              ),
              const SizedBox(width: 8),
              if (w != null)
                FilledButton.icon(
                  icon: const Icon(Icons.navigation),
                  label: const Text('Navigate here'),
                  onPressed: () async {
                    await Navigator.push(context, MaterialPageRoute<void>(
                        builder: (_) => NavigateScreen(store: widget.store, site: site, check: widget.check)));
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
          _heading('Visits'),
          for (final v in visits)
            Card(
              child: ListTile(
                title: Text('${v.kind.label}, ${v.time.toLocal().toString().substring(0, 16)}'),
                subtitle: Text(
                  '${v.livePhotos.length} photo${v.livePhotos.length == 1 ? '' : 's'}'
                  '${v.notes.isEmpty ? '' : ' · ${v.notes.split('\n').first}'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  await Navigator.push(context, MaterialPageRoute<void>(
                      builder: (_) => VisitScreen(store: widget.store, site: site, visit: v)));
                  if (mounted) setState(() {});
                },
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: Text(visits.isEmpty ? 'Add the setup visit (photos and notes)' : 'Add a visit (photos and notes)'),
            onPressed: _addVisit,
          ),
        ],
      ),
    );
  }

  List<Widget> _fields() {
    Widget field(String label, String value, int maxLen, void Function(String) set,
            {String? hint, bool digits = false}) =>
        TextFormField(
          key: ValueKey('$label$_formVersion'),
          initialValue: value,
          maxLength: maxLen,
          keyboardType: digits ? TextInputType.number : TextInputType.text,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            counterText: '',
            floatingLabelBehavior: hint == null ? null : FloatingLabelBehavior.always,
          ),
          inputFormatters: [
            digits ? FilteringTextInputFormatter.digitsOnly : FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
            TextInputFormatter.withFunction((old, now) => now.copyWith(text: now.text.toUpperCase())),
          ],
          onChanged: (s) {
            set(s);
            _fieldsChanged();
          },
        );
    final rate = site.sampleRate;
    return [
      field('Serial number', site.serialNumber, 9, (s) => site.serialNumber = s, digits: true),
      Row(
        children: [
          Expanded(child: field('Network', site.network, 2, (s) => site.network = s)),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: field('Station', site.station, 5, (s) => site.station = s)),
          const SizedBox(width: 12),
          Expanded(child: field('Location', site.location, 2, (s) => site.location = s)),
        ],
      ),
      Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: field('Channel ${i + 1}', site.channels[i], 3, (s) => site.channels[i] = s,
                  hint: rate == null ? 'default' : BootReport.defaultChannelCode(i, rate)),
            ),
          ],
        ],
      ),
      if (rate == null)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('Leave channel codes blank for the logger\'s defaults.', style: TextStyle(color: Colors.black54)),
        ),
    ];
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      );
}

/// Fills a site's serial number, codes, and sample rate from what a logger reports (Check tab): the codes as the
/// logger records them.
void fillSiteFromLogger(Site site, int serial, LoggerSettings s) {
  site
    ..serialNumber = '$serial'
    ..network = s.network
    ..station = s.station
    ..location = s.location
    ..sampleRate = s.sampleRate
    ..channels = [for (var i = 0; i < 4; i++) s.gains[i] > 0 ? s.channels[i] : ''];
}

/// "1.2 km away", for lists.
String distanceText(Waypoint w, double lat, double lon) => '${formatDistance(distanceMeters(lat, lon, w.lat, w.lon))} away';
