import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../check_session.dart';
import 'marked_photo.dart';
import 'marker_editor_screen.dart';
import 'site_model.dart';
import 'site_store.dart';

/// One visit to a site: setup, service, or pickup, with notes and photos.
class VisitScreen extends StatefulWidget {
  const VisitScreen({super.key, required this.store, required this.site, required this.visit});

  final SiteStore store;
  final Site site;
  final Visit visit;

  @override
  State<VisitScreen> createState() => _VisitScreenState();
}

class _VisitScreenState extends State<VisitScreen> {
  late final notes = TextEditingController(text: widget.visit.notes);
  Timer? _saveNotes;
  bool busy = false;

  Visit get visit => widget.visit;

  @override
  void dispose() {
    if (_saveNotes?.isActive ?? false) {
      _saveNotes!.cancel();
      _storeNotes();
    }
    notes.dispose();
    super.dispose();
  }

  void _storeNotes() {
    if (visit.notes == notes.text) return;
    visit.notes = notes.text;
    unawaited(widget.store.saveVisit(widget.site, visit));
  }

  Future<void> _addPhoto(ImageSource source) async {
    setState(() => busy = true);
    try {
      // Saved at most 2048 pixels across: plenty to spot a buried sensor, and small enough (~0.5 MB) to send.
      final picked = await ImagePicker().pickImage(source: source, maxWidth: 2048, maxHeight: 2048, imageQuality: 85);
      if (picked == null) return;
      final photo = await widget.store.addPhoto(widget.site, visit, picked.path);
      if (!mounted) return;
      setState(() {});
      await Navigator.push(context, MaterialPageRoute<void>(
          builder: (_) => MarkerEditorScreen(store: widget.store, site: widget.site, photo: photo)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not get the photo: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this visit?'),
        content: const Text('Its notes and photos will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    _saveNotes?.cancel();
    await widget.store.deleteVisit(widget.site, visit);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final photos = visit.livePhotos.toList();
    final local = visit.time.toLocal();
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.site.title}: ${visit.kind.label}'),
        actions: [IconButton(tooltip: 'Delete visit', icon: const Icon(Icons.delete_outline), onPressed: _delete)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<VisitKind>(
            segments: [for (final k in VisitKind.values) ButtonSegment(value: k, label: Text(k.label))],
            selected: {visit.kind},
            onSelectionChanged: (s) {
              setState(() => visit.kind = s.first);
              unawaited(widget.store.saveVisit(widget.site, visit));
            },
          ),
          const SizedBox(height: 8),
          Text('${local.toString().substring(0, 16)} (phone time)', style: const TextStyle(color: Colors.black54)),
          if (visit.startupLog != null)
            Text('Startup log: ${visit.startupLog}', style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          TextField(
            controller: notes,
            minLines: 3,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Notes',
              helperText: 'To dictate, tap the microphone on the keyboard.',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              _saveNotes?.cancel();
              _saveNotes = Timer(const Duration(seconds: 1), _storeNotes);
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Photos (${photos.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              if (busy) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in photos)
                GestureDetector(
                  onTap: () async {
                    await Navigator.push(context, MaterialPageRoute<void>(
                        builder: (_) => MarkerEditorScreen(store: widget.store, site: widget.site, photo: p)));
                    if (mounted) setState(() {});
                  },
                  child: SizedBox(
                    width: 150,
                    height: 150,
                    child: MarkedPhoto(
                      file: widget.store.photoFile(widget.site, p),
                      markers: p.markers,
                      cacheWidth: 300,
                      showLabels: false,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Take photo'),
                  onPressed: busy ? null : () => _addPhoto(ImageSource.camera),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('From gallery'),
                onPressed: busy ? null : () => _addPhoto(ImageSource.gallery),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('After taking a photo, tap where each sensor is hidden to mark it.',
              style: TextStyle(color: Colors.black54)),
        ],
      ),
    );
  }
}

/// Adds a visit to a site (the setup visit if it's the first) and opens it. If the Check tab is talking to this
/// site's logger, its startup log is linked to the visit (and goes into exports).
Future<void> addVisitAndOpen(BuildContext context, SiteStore store, Site site, CheckSession check) async {
  final sameLogger = check.report.serialNumber != null && site.serialNumber == '${check.report.serialNumber}';
  await check.flushLog();
  final v = Visit(
    time: DateTime.now().toUtc(),
    kind: site.liveVisits.isEmpty ? VisitKind.setup : VisitKind.service,
    startupLog: sameLogger ? check.logFileName : null,
  );
  site.visits.add(v);
  await store.saveVisit(site, v);
  if (!context.mounted) return;
  await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => VisitScreen(store: store, site: site, visit: v)));
}
