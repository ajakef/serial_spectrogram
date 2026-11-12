import 'package:flutter/material.dart';

import 'boot_report.dart';
import 'check_session.dart';
import 'config_editor.dart';
import 'config_file.dart';
import 'saved_logs_screen.dart';

/// The Check tab: what the logger reports as it starts, as a checklist (field view) or in full (engineer view).
class CheckScreen extends StatefulWidget {
  const CheckScreen({super.key, required this.session});

  final CheckSession session;

  @override
  State<CheckScreen> createState() => _CheckScreenState();
}

class _CheckScreenState extends State<CheckScreen> {
  static bool engineer = false; // kept while the app runs
  bool showAllLines = false;

  CheckSession get session => widget.session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final report = session.report;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Check'),
            actions: [
              IconButton(
                tooltip: 'Check again (restarts the logger)',
                icon: const Icon(Icons.refresh),
                onPressed: session.connected && !session.writing ? session.checkAgain : null,
              ),
              IconButton(
                tooltip: 'Saved startup logs',
                icon: const Icon(Icons.folder_open),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => const SavedLogsScreen())),
              ),
            ],
          ),
          body: !session.connected && !report.booted
              ? _plugIn()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  children: [
                    if (!session.connected) _unpluggedStrip(),
                    _banner(report),
                    if (session.writeStage != WriteStage.idle) _writeCard(),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('Field'), icon: Icon(Icons.checklist)),
                          ButtonSegment(value: true, label: Text('Engineer'), icon: Icon(Icons.engineering)),
                        ],
                        selected: {engineer},
                        onSelectionChanged: (s) => setState(() => engineer = s.first),
                      ),
                    ),
                    ...(engineer ? _engineerView(report) : _fieldView(report)),
                  ],
                ),
        );
      },
    );
  }

  Widget _plugIn() {
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Plug in the Aspen logger', style: TextStyle(fontSize: 18)),
              Text(session.status, style: const TextStyle(color: Colors.grey)),
              TextButton(onPressed: session.link.connect, child: const Text('Connect')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unpluggedStrip() {
    return Card(
      color: Colors.grey.shade300,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.usb_off),
        title: const Text('Unplugged: showing the last check'),
        trailing: TextButton(onPressed: session.link.connect, child: const Text('Connect')),
      ),
    );
  }

  static Color colorFor(CheckState s) => switch (s) {
        CheckState.ok => Colors.green.shade700,
        CheckState.warn => Colors.orange.shade800,
        CheckState.fail => Colors.red.shade700,
        CheckState.pending => Colors.blueGrey,
      };

  static Widget iconFor(CheckState s, {double size = 24}) => switch (s) {
        CheckState.ok => Icon(Icons.check_circle, color: colorFor(s), size: size),
        CheckState.warn => Icon(Icons.warning_amber_rounded, color: colorFor(s), size: size),
        CheckState.fail => Icon(Icons.error, color: colorFor(s), size: size),
        CheckState.pending => Icon(Icons.radio_button_unchecked, color: colorFor(s), size: size),
      };

  Widget _banner(BootReport report) {
    final o = report.overall;
    final busy = o.state == CheckState.pending || (o.state == CheckState.warn && !report.gpsLocked && session.connected);
    return Card(
      color: colorFor(o.state).withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            busy && session.connected
                ? const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3))
                : iconFor(o.state, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(o.headline, style: TextStyle(fontSize: 20, color: colorFor(o.state), fontWeight: FontWeight.w600)),
                  if (o.detail.isNotEmpty) Text(o.detail),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _writeCard() {
    final stage = session.writeStage;
    final busy = session.writing;
    final color = switch (stage) {
      WriteStage.done => Colors.green.shade700,
      WriteStage.failed => Colors.red.shade700,
      _ => Colors.blueGrey,
    };
    return Card(
      child: ListTile(
        leading: busy
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3))
            : Icon(stage == WriteStage.done ? Icons.check_circle : Icons.error, color: color),
        title: Text(busy ? 'Saving settings' : (stage == WriteStage.done ? 'Settings saved' : 'Settings not saved')),
        subtitle: Text(session.writeMessage),
        trailing: busy ? null : IconButton(icon: const Icon(Icons.close), onPressed: session.dismissWrite),
      ),
    );
  }

  List<Widget> _fieldView(BootReport report) {
    final s = report.settings;
    final configBad = report.items['config']!.state == CheckState.fail;
    return [
      Card(
        child: Column(
          children: [for (final item in report.items.values) _itemTile(item)],
        ),
      ),
      if (s != null) _settingsCard(s, report),
      if (s != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: configBad
              ? FilledButton.icon(
                  icon: const Icon(Icons.build),
                  label: const Text('Fix CONFIG.TXT'),
                  style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                  onPressed: _canEdit ? () => _openEditor(report) : null,
                )
              : OutlinedButton.icon(
                  icon: const Icon(Icons.edit),
                  label: const Text('Change settings'),
                  onPressed: _canEdit ? () => _openEditor(report) : null,
                ),
        ),
    ];
  }

  bool get _canEdit => session.connected && !session.writing;

  Future<void> _openEditor(BootReport report) async {
    final values = ConfigValues.fromReport(report.settings!, serialNumber: report.serialNumber);
    final save = await Navigator.push<ConfigValues>(
      context,
      MaterialPageRoute(builder: (_) => ConfigEditorScreen(initial: values, serialNumber: report.serialNumber)),
    );
    if (save != null) await session.saveConfig(save);
  }

  Widget _itemTile(CheckItem item, {bool dense = false}) {
    return ListTile(
      dense: dense,
      leading: iconFor(item.state),
      title: Text(item.title),
      subtitle: item.detail.isEmpty && item.notes.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.detail.isNotEmpty) Text(item.detail),
                for (final n in item.notes)
                  Text('• $n', style: TextStyle(color: colorFor(item.state == CheckState.fail ? CheckState.fail : CheckState.warn))),
              ],
            ),
    );
  }

  Widget _settingsCard(LoggerSettings s, BootReport report) {
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 110, child: Text(label, style: const TextStyle(color: Colors.black54))),
              Expanded(child: Text(value)),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Settings in use', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            row('Channels', '${s.channelCount} on: ${s.channelsText}'),
            row('Sample rate', '${s.sampleRate} samples per second'),
            row('GPS', s.gpsText),
            row('Station', s.stationText),
            if (s.fileMinutes != null) row('Files', _fileLength(s.fileMinutes!)),
          ],
        ),
      ),
    );
  }

  static String _fileLength(int minutes) =>
      minutes % 1440 == 0 ? 'a new file every ${minutes ~/ 1440} day${minutes == 1440 ? '' : 's'}' : 'a new file every $minutes min';

  // ---- engineer view ----

  List<Widget> _engineerView(BootReport report) {
    final mono = TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.grey.shade900);
    final h = report.health;
    final s = report.settings;
    return [
      _section('Logger', [
        _kv('Firmware', report.firmware ?? '?'),
        _kv('Reset cause', report.resetCause ?? '?'),
        if (report.previousBootReached != null) _kv('Previous boot stopped at', report.previousBootReached!, warn: true),
        _kv('Serial number', report.serialNumber?.toString() ?? '?'),
        if (report.bootBattV != null) _kv('At startup', 'Vbatt ${report.bootBattV} V, Vcc ${report.bootVcc} V'),
        if (report.infrasoundOnlyUnit) _kv('Unit type', 'infrasound only (TYPE_SENSE grounded)'),
        for (final c in report.errorCodes) _kv('Error code $c', errorCodeMeanings[c] ?? 'unknown', warn: true),
      ]),
      Card(child: Column(children: [for (final item in report.items.values) _itemTile(item, dense: true)])),
      _section('Settings ("Config:" line)', [
        if (s == null) const Text('Not reported yet'),
        if (s != null) ...[
          _kv('Gains', s.gains.join(', ')),
          _kv('Sample rate', '${s.sampleRate} sps'),
          _kv('GPS', 'mode ${s.gpsMode}, cycle ${s.gpsCycleMinutes} min, quota ${s.gpsQuota}'
              '${s.gpsSettleS != null ? ', settle ${s.gpsSettleS} s' : ''}'),
          _kv('SEED codes', '${s.stationId}.${s.channels.join('/')}'),
          if (s.fileMinutes != null) _kv('File length', '${s.fileMinutes} min'),
        ],
        if (report.commandReplies.isNotEmpty) _kv('Command replies', report.commandReplies.join('\n')),
      ]),
      _section('CONFIG.TXT on the card', _configFileLines(report, mono)),
      _section('Latest health line', [
        if (h == null) const Text('None yet'),
        if (h != null) ..._healthRows(report),
      ]),
      _section('Startup log', [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Include health lines and GPS messages'),
          value: showAllLines,
          onChanged: (v) => setState(() => showAllLines = v),
        ),
        ..._logLines(report, mono),
      ]),
    ];
  }

  Widget _section(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              ...children,
            ],
          ),
        ),
      );

  Widget _kv(String k, String v, {bool warn = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 130, child: Text(k, style: const TextStyle(color: Colors.black54))),
            Expanded(child: SelectableText(v, style: TextStyle(color: warn ? Colors.orange.shade900 : null))),
          ],
        ),
      );

  List<Widget> _configFileLines(BootReport report, TextStyle mono) {
    final t = report.configFile;
    final out = <Widget>[];
    if (report.configValuesRead != null) out.add(_kv('Values read', report.configValuesRead!));
    if (t == null) {
      out.add(Text(report.configFileFound == false
          ? 'No CONFIG.TXT on the card'
          : 'Not received (firmware without the GT: command sends nothing)'));
      return out;
    }
    if (t.error != null) {
      out.add(Text('Could not read it: ${t.error}', style: TextStyle(color: Colors.red.shade700)));
      return out;
    }
    final notes = report.configLines;
    if (notes == null) {
      out.add(SelectableText(t.text ?? '', style: mono));
      return out;
    }
    for (final n in notes) {
      out.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${n.lineNumber.toString().padLeft(2)}  ${n.text}', style: mono),
            if (n.setting != null && n.problem == null)
              Text('     → ${n.setting}', style: mono.copyWith(color: Colors.black45)),
            if (n.problem != null)
              Text('     ⚠ ${n.problem}', style: mono.copyWith(color: Colors.red.shade700)),
          ],
        ),
      ));
    }
    return out;
  }

  List<Widget> _healthRows(BootReport report) {
    final raw = report.lines.lastWhere((l) => BootReport.strip(l.text).startsWith('H,')).text;
    final fields = BootReport.strip(raw).split(',').sublist(1);
    const first = HealthLine.firstFields;
    const later = HealthLine.laterFields;
    final named = fields.length == first.length + later.length;
    String show(String f) => f.isEmpty ? '(blank)' : f;
    return [
      for (var i = 0; i < fields.length && (named || i < first.length); i++)
        _kv(i < first.length ? first[i] : later[i - first.length], show(fields[i])),
      // other firmware versions have other fields here: see the #H header line in the logger's log file
      if (!named && fields.length > first.length)
        _kv('Fields ${first.length + 1}-${fields.length}', fields.sublist(first.length).map(show).join(', ')),
    ];
  }

  List<Widget> _logLines(BootReport report, TextStyle mono) {
    final shown = report.lines.where((l) => showAllLines || l.kind != LineKind.data).toList();
    const limit = 400;
    final start = shown.length > limit ? shown.length - limit : 0;
    return [
      if (start > 0) Text('(${shown.length - limit} earlier lines are in the saved log)', style: mono),
      for (final l in shown.sublist(start))
        Text(l.text,
            style: mono.copyWith(
              color: switch (l.kind) {
                LineKind.bad => Colors.red.shade700,
                LineKind.warn => Colors.orange.shade900,
                LineKind.good => Colors.green.shade800,
                LineKind.data => Colors.black45,
                LineKind.normal => null,
              },
            )),
    ];
  }
}
