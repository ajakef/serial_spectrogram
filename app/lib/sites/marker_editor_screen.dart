import 'package:flutter/material.dart';

import 'marked_photo.dart';
import 'site_model.dart';
import 'site_store.dart';

/// One photo, full screen: tap where a sensor is hidden to mark it; drag a marker to move it; tap it to rename or
/// remove it.
class MarkerEditorScreen extends StatefulWidget {
  const MarkerEditorScreen({super.key, required this.store, required this.site, required this.photo});

  final SiteStore store;
  final Site site;
  final SitePhoto photo;

  @override
  State<MarkerEditorScreen> createState() => _MarkerEditorScreenState();
}

class _MarkerEditorScreenState extends State<MarkerEditorScreen> {
  SitePhoto get photo => widget.photo;

  Future<void> _save() => widget.store.savePhoto(widget.site, photo);

  Future<void> _add(double x, double y) async {
    final label = await pickMarkerLabel(context);
    if (label == null) return;
    setState(() => photo.markers.add(Marker(x: x, y: y, label: label)));
    await _save();
  }

  Future<void> _edit(int i) async {
    final m = photo.markers[i];
    final label = await pickMarkerLabel(context, current: m.label, canRemove: true);
    if (label == null) return;
    setState(() {
      if (label.isEmpty) {
        photo.markers.removeAt(i);
      } else {
        m.label = label;
      }
    });
    await _save();
  }

  Future<void> _deletePhoto() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this photo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.deletePhoto(widget.site, photo);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Mark hidden sensors'),
        actions: [IconButton(tooltip: 'Delete photo', icon: const Icon(Icons.delete_outline), onPressed: _deletePhoto)],
      ),
      body: Column(
        children: [
          Expanded(
            child: MarkedPhoto(
              file: widget.store.photoFile(widget.site, photo),
              markers: photo.markers,
              onTapPhoto: _add,
              onTapMarker: _edit,
              onDragMarker: (i, x, y) => setState(() {
                photo.markers[i]
                  ..x = x
                  ..y = y;
              }),
              onDragEnd: _save,
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Tap the photo where a sensor is hidden. Drag a marker to move it; tap it to rename or remove it.',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a marker's label: a kind (Logger, Seismic, Infrasound, Battery) and an optional number, e.g. "Seismic 2".
/// Returns null if cancelled, or '' for "remove" (when [canRemove]).
Future<String?> pickMarkerLabel(BuildContext context, {String? current, bool canRemove = false}) {
  var kind = Marker.kinds.first;
  int? number;
  if (current != null) {
    final parts = current.split(' ');
    if (Marker.kinds.contains(parts.first)) kind = parts.first;
    number = parts.length > 1 ? int.tryParse(parts.last) : null;
  }
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('What is hidden here?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final k in Marker.kinds)
                  ChoiceChip(label: Text(k), selected: k == kind, onSelected: (_) => setSheet(() => kind = k)),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Number (optional)'),
            Wrap(
              spacing: 6,
              children: [
                ChoiceChip(label: const Text('none'), selected: number == null, onSelected: (_) => setSheet(() => number = null)),
                for (var n = 1; n <= 9; n++)
                  ChoiceChip(label: Text('$n'), selected: number == n, onSelected: (_) => setSheet(() => number = n)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (canRemove)
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove marker'),
                    onPressed: () => Navigator.pop(context, ''),
                  ),
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () => Navigator.pop(context, number == null ? kind : '$kind $number'),
                  child: Text(number == null ? kind : '$kind $number'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
