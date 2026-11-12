import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../check_session.dart';
import 'phone.dart';
import 'site_exchange.dart';
import 'site_model.dart';
import 'site_screen.dart';
import 'site_store.dart';

/// The Sites tab: the list of sites, and sending them to (or merging them from) other phones and computers.
///
/// Sharing between phones needs no accounts: "Send all sites" makes one zip file, which Android's Share menu can send
/// by Quick Share (phone to phone, works without cell service), email, or anything else; on the other phone, "Import
/// sites from a file" merges it in, keeping the newest version of everything.
class SitesScreen extends StatefulWidget {
  const SitesScreen({super.key, required this.store, required this.check});

  final SiteStore store;
  final CheckSession check;

  @override
  State<SitesScreen> createState() => _SitesScreenState();
}

class _SitesScreenState extends State<SitesScreen> {
  SiteStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    store.load();
  }

  Future<void> _newSite() async {
    final site = await store.newSite();
    final r = widget.check.report;
    if (r.serialNumber != null && r.settings != null) {
      fillSiteFromLogger(site, r.serialNumber!, r.settings!); // the logger plugged in on the Check tab
      await store.save(site, fields: true);
    }
    await _open(site);
  }

  Future<void> _open(Site site) async {
    await Navigator.push(
        context, MaterialPageRoute<void>(builder: (_) => SiteScreen(store: store, site: site, check: widget.check)));
    if (mounted) setState(() {});
  }

  /// Makes the export zip, showing progress; null if it failed.
  Future<File?> _export() async {
    final progress = ValueNotifier<String>('Starting');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Packing the sites'),
        content: ValueListenableBuilder<String>(
          valueListenable: progress,
          builder: (_, text, _) => Row(children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 16),
            Expanded(child: Text(text)),
          ]),
        ),
      ),
    );
    try {
      return await exportSites(store, store.sites, progress: (s) => progress.value = s);
    } catch (e) {
      _message('Could not pack the sites: $e');
      return null;
    } finally {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _send() async {
    final zip = await _export();
    if (zip == null) return;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(zip.path, mimeType: 'application/zip')],
      subject: 'Aspen sites',
      text: 'Aspen field sites (open README.txt inside for what\'s what; import into the app from the Sites tab).',
    ));
  }

  Future<void> _saveToDownloads() async {
    final zip = await _export();
    if (zip == null) return;
    try {
      final where = await Phone.saveToDownloads(zip.path, zip.path.split('/').last, 'application/zip');
      _message('Saved to $where');
    } catch (e) {
      _message('Could not save it: $e');
    }
  }

  Future<void> _import() async {
    final picked = await Phone.pickFileToCache();
    if (picked == null) return;
    try {
      final r = await importSites(store, picked.path);
      _message('${r.added} new site${r.added == 1 ? '' : 's'}, ${r.updated} updated, ${r.photos} new photo${r.photos == 1 ? '' : 's'}');
    } on FormatException catch (e) {
      _message(e.message);
    } catch (e) {
      _message('Could not import ${picked.name}: $e');
    } finally {
      await File(picked.path).delete().catchError((_) => File(picked.path));
    }
    if (mounted) setState(() {});
  }

  void _message(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final sites = store.sites;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Sites'),
            actions: [
              PopupMenuButton<String>(
                onSelected: (choice) => switch (choice) {
                  'send' => _send(),
                  'save' => _saveToDownloads(),
                  _ => _import(),
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'send', enabled: sites.isNotEmpty, child: const Text('Send all sites...')),
                  PopupMenuItem(value: 'save', enabled: sites.isNotEmpty, child: const Text('Save a copy to Downloads')),
                  const PopupMenuItem(value: 'import', child: Text('Import sites from a file...')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add_location_alt),
            label: const Text('New site'),
            onPressed: store.loaded ? _newSite : null,
          ),
          body: !store.loaded
              ? const Center(child: CircularProgressIndicator())
              : sites.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No sites yet.\n\nAt a new site, plug in the logger and check it on the Check tab, then tap '
                          'New site: its serial number and codes are filled in for you. Then take a waypoint, photos '
                          'of where the sensors are hidden, and notes.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 88),
                      children: [
                        for (final s in sites)
                          ListTile(
                            leading: Icon(s.waypoint == null ? Icons.location_off_outlined : Icons.place,
                                color: s.waypoint == null ? Colors.black38 : Colors.blue.shade700),
                            title: Text(s.title),
                            subtitle: Text(_summary(s)),
                            onTap: () => _open(s),
                          ),
                      ],
                    ),
        );
      },
    );
  }

  static String _summary(Site s) {
    final visits = s.visitsNewestFirst;
    return [
      if (s.serialNumber.isNotEmpty) 'SN ${s.serialNumber}',
      if (visits.isNotEmpty) 'last visit ${visits.first.time.toLocal().toString().substring(0, 10)}',
      '${visits.fold<int>(0, (n, v) => n + v.livePhotos.length)} photos',
      if (s.waypoint == null) 'no waypoint',
    ].join(' · ');
  }
}
