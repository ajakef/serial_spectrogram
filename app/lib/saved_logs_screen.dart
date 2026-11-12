import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'check_session.dart';

/// The startup logs saved on the phone by the Check tab (one per check), to read or send later, e.g. once there's
/// cell service. Sending uses Android's Share menu (email, messaging, Drive, Quick Share to a nearby phone...).
class SavedLogsScreen extends StatefulWidget {
  const SavedLogsScreen({super.key});

  @override
  State<SavedLogsScreen> createState() => _SavedLogsScreenState();
}

class _SavedLogsScreenState extends State<SavedLogsScreen> {
  List<File>? files;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await LogRecorder.saved();
    if (mounted) setState(() => files = f);
  }

  static String _name(File f) => f.path.split('/').last;

  static String _size(int bytes) =>
      bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(0)} kB' : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  Future<void> _share(List<File> which) async {
    if (which.isEmpty) return;
    await SharePlus.instance.share(ShareParams(
      files: [for (final f in which) XFile(f.path, mimeType: 'text/plain')],
      subject: which.length == 1 ? _name(which.first) : 'Aspen startup logs',
    ));
  }

  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this log?'),
        content: Text(_name(f)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await f.delete();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = files;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved startup logs'),
        actions: [
          IconButton(
            tooltip: 'Send all',
            icon: const Icon(Icons.share),
            onPressed: list == null || list.isEmpty ? null : () => _share(list),
          ),
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? const Center(child: Text('No logs yet. Each check on the Check tab saves one.'))
              : ListView(
                  children: [
                    for (final f in list)
                      ListTile(
                        title: Text(_name(f)),
                        subtitle: Text('${_size(f.lengthSync())} · saved ${f.lastModifiedSync().toLocal().toString().substring(0, 16)}'),
                        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _LogView(file: f))),
                        onLongPress: () => _delete(f),
                        trailing: IconButton(tooltip: 'Send', icon: const Icon(Icons.share), onPressed: () => _share([f])),
                      ),
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Tap a log to read it, or press and hold to delete it. Logs are kept on this phone '
                          'until deleted (uninstalling the app deletes them).', style: TextStyle(color: Colors.black54)),
                    ),
                  ],
                ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(file.path.split('/').last)),
      body: FutureBuilder<List<String>>(
        future: file.readAsLines(),
        builder: (context, snap) {
          final lines = snap.data;
          if (lines == null) return const Center(child: CircularProgressIndicator());
          return Scrollbar(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: lines.length,
              itemBuilder: (context, i) =>
                  Text(lines[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            ),
          );
        },
      ),
    );
  }
}
