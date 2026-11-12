import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'boot_report.dart';
import 'config_file.dart';

/// Form for the settings in CONFIG.TXT. "Save to logger" returns the new values to the Check tab, which sends them to
/// the logger and has it save them (the old file is kept on the card as CONFIG.BAK).
class ConfigEditorScreen extends StatefulWidget {
  const ConfigEditorScreen({super.key, required this.initial, this.serialNumber});

  final ConfigValues initial;
  final int? serialNumber;

  @override
  State<ConfigEditorScreen> createState() => _ConfigEditorScreenState();
}

class _ConfigEditorScreenState extends State<ConfigEditorScreen> {
  late final ConfigValues v = ConfigValues(
    gains: List.of(widget.initial.gains),
    sampleRate: widget.initial.sampleRate,
    gpsMode: widget.initial.gpsMode,
    gpsCycleMinutes: widget.initial.gpsCycleMinutes,
    gpsQuota: widget.initial.gpsQuota,
    network: widget.initial.network,
    station: widget.initial.station,
    location: widget.initial.location,
    channels: List.of(widget.initial.channels),
  );

  static const channelNames = ['infrasound', 'seismic Z', 'seismic N', 'seismic E'];
  static const gpsModes = {
    1: 'Cycled: on until the quota of fixes, then off',
    2: 'Always on (more power)',
    3: 'Off (no GPS timing)',
    4: 'Cycled, with the cycle adjusted to keep timing errors small',
  };

  @override
  Widget build(BuildContext context) {
    final problems = v.problems();
    return Scaffold(
      appBar: AppBar(title: const Text('Logger settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _heading('Channels'),
          for (var i = 0; i < 4; i++)
            _row(
              'Channel ${i + 1} (${channelNames[i]})',
              DropdownButton<int>(
                value: v.gains[i],
                items: [
                  for (final g in allowedGains) DropdownMenuItem(value: g, child: Text(g == 0 ? 'off' : 'gain $g')),
                ],
                onChanged: (g) => setState(() => v.gains[i] = g!),
              ),
            ),
          _row(
            'Sample rate',
            DropdownButton<int>(
              value: v.sampleRate,
              items: [for (final r in allowedRates) DropdownMenuItem(value: r, child: Text('$r per second'))],
              onChanged: (r) => setState(() => v.sampleRate = r!),
            ),
          ),
          _heading('GPS'),
          DropdownButton<int>(
            isExpanded: true,
            value: v.gpsMode,
            items: [
              for (final e in gpsModes.entries)
                DropdownMenuItem(value: e.key, child: Text('${e.key}: ${e.value}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (m) => setState(() => v.gpsMode = m!),
          ),
          if (v.gpsMode == 1 || v.gpsMode == 4) ...[
            _number('Cycle (minutes)', v.gpsCycleMinutes, (n) => v.gpsCycleMinutes = n),
            _number('Quota (fixes per cycle)', v.gpsQuota, (n) => v.gpsQuota = n),
          ],
          _heading('SEED codes'),
          const Text('Leave blank for the default.', style: TextStyle(color: Colors.black54)),
          _code('Network', v.network, 2, 'none', (s) => v.network = s),
          _code('Station', v.station, 5,
              widget.serialNumber == null ? 'serial number' : (widget.serialNumber! % 100000).toString().padLeft(5, '0'),
              (s) => v.station = s),
          _code('Location', v.location, 2, 'none', (s) => v.location = s),
          for (var i = 0; i < 4; i++)
            if (v.gains[i] > 0)
              _code('Channel ${i + 1}', v.channels[i], 3, BootReport.defaultChannelCode(i, v.sampleRate),
                  (s) => v.channels[i] = s),
          const SizedBox(height: 16),
          for (final p in problems) Text('• $p', style: TextStyle(color: Colors.red.shade700)),
          for (final w in BootReport.settingsWarnings(_asSettings())) Text('• $w', style: TextStyle(color: Colors.orange.shade900)),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.save),
            label: const Text('Save to logger'),
            onPressed: problems.isEmpty ? () => Navigator.pop(context, v) : null,
          ),
          const SizedBox(height: 8),
          const Text(
            'The logger restarts, takes these settings, and saves them to CONFIG.TXT (the old file is kept as '
            'CONFIG.BAK). Then it restarts again so the Check tab can confirm it reads the new file.',
            style: TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }

  // The values as the logger would report them, for the amber warnings.
  LoggerSettings _asSettings() => LoggerSettings(
        gains: v.gains,
        sampleRate: v.sampleRate,
        gpsMode: v.gpsMode,
        gpsCycleMinutes: v.gpsCycleMinutes,
        gpsQuota: v.gpsQuota,
        network: v.network,
        station: v.station,
        location: v.location,
        channels: [for (var i = 0; i < 4; i++) v.channelCode(i)],
      );

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      );

  Widget _row(String label, Widget field) => Row(children: [Expanded(child: Text(label)), field]);

  Widget _number(String label, int value, void Function(int) set) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextFormField(
          initialValue: '$value',
          decoration: InputDecoration(labelText: label),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
          onChanged: (s) => setState(() => set(int.tryParse(s) ?? 0)),
        ),
      );

  Widget _code(String label, String value, int maxLen, String hint, void Function(String) set) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextFormField(
          initialValue: value,
          decoration: InputDecoration(
            labelText: label,
            hintText: 'default: $hint',
            counterText: '',
            floatingLabelBehavior: FloatingLabelBehavior.always, // so the default shows while the field is empty
          ),
          maxLength: maxLen,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
            TextInputFormatter.withFunction((old, now) => now.copyWith(text: now.text.toUpperCase())),
          ],
          onChanged: (s) => setState(() => set(s)),
        ),
      );
}
