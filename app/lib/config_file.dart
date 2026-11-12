import 'boot_report.dart';

/// CONFIG.TXT as the firmware reads it today: one value per line, in a fixed order, with optional "# comments".
/// Blank lines and comment-only lines are skipped. (aspen-firmware other_functions.h ReadConfig; if the file format
/// changes, e.g. to "name=value" lines, update this file and [ConfigValues.commands] stays the same.)
const configSettingNames = [
  'channel 1 gain', 'channel 2 gain', 'channel 3 gain', 'channel 4 gain', 'sample rate', 'gps_mode',
  'gps_cycle_minutes', 'gps_quota', 'use_compression', 'network code', 'station code', 'location code',
  'channel 1 code', 'channel 2 code', 'channel 3 code', 'channel 4 code',
];

// Words in a comment that name each setting, to spot a missing or extra line (every value after it shifts).
final _commentPatterns = [
  for (var i = 1; i <= 4; i++) RegExp('channel\\s*$i\\s*gain'),
  RegExp(r'sample[ _]rate'),
  RegExp(r'gps[ _]mode'),
  RegExp(r'cycle'),
  RegExp(r'quota'),
  RegExp(r'compression'),
  RegExp(r'network'),
  RegExp(r'station'),
  RegExp(r'location'),
  for (var i = 1; i <= 4; i++) RegExp('channel\\s*$i\\s*code'),
];

const allowedGains = [0, 1, 2, 4, 8, 16, 32, 64, 128];
const allowedRates = [100, 200, 400, 800, 1000];

/// One line of CONFIG.TXT, with the setting it's read as and anything wrong with it.
class ConfigLineNote {
  ConfigLineNote(this.lineNumber, this.text, {this.setting, this.problem});
  final int lineNumber; // 1-based, counting every line in the file
  final String text;
  final String? setting; // null for blank/comment-only lines and extra lines
  final String? problem;
}

/// Goes through the file's lines as the firmware would. Returns null if the file isn't in the one-value-per-line
/// format (then the app just shows it).
List<ConfigLineNote>? checkConfigFile(String text) {
  final lines = text.replaceAll('\r', '').split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final notes = <ConfigLineNote>[];
  var index = 0; // which setting the next value line is read as
  for (var n = 0; n < lines.length; n++) {
    final line = lines[n];
    final hash = line.indexOf('#');
    final value = (hash >= 0 ? line.substring(0, hash) : line).replaceAll(RegExp(r'[ \t]'), '');
    final comment = hash >= 0 ? line.substring(hash + 1).toLowerCase() : '';
    if (value.isEmpty) {
      notes.add(ConfigLineNote(n + 1, line));
      continue;
    }
    if (value.contains('=')) return null; // "name=value" lines: a different format
    if (index >= configSettingNames.length) {
      notes.add(ConfigLineNote(n + 1, line, problem: 'Extra line: the logger ignores it'));
      continue;
    }
    final name = configSettingNames[index];
    var problem = _valueProblem(index, value);
    if (problem == null && comment.isNotEmpty && !_commentPatterns[index].hasMatch(comment)) {
      final other = [for (var k = 0; k < _commentPatterns.length; k++) if (_commentPatterns[k].hasMatch(comment)) k];
      if (other.isNotEmpty) {
        problem = 'Read as $name, but its comment says ${configSettingNames[other.first]}: '
            'is a line above it missing or extra?';
      }
    }
    notes.add(ConfigLineNote(n + 1, line, setting: name, problem: problem));
    index++;
  }
  if (index < 9) {
    notes.add(ConfigLineNote(lines.length + 1, '',
        problem: 'Only $index of the first 9 settings are in the file: '
            '${configSettingNames.sublist(index, 9).join(', ')} use defaults'));
  }
  return notes;
}

/// What the firmware would reject in a value (its checks in ReadConfig), or null.
String? _valueProblem(int index, String value) {
  if (index >= 9) {
    if (value == '-') return null;
    final maxLen = const [2, 5, 2, 3, 3, 3, 3][index - 9];
    final exact = index >= 12;
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(value)) return 'Codes may hold only letters and digits ("-" for the default)';
    if (exact && value.length != maxLen) return 'Channel codes need exactly 3 characters';
    if (value.length > maxLen) return 'At most $maxLen characters';
    return null;
  }
  final number = int.tryParse(RegExp(r'^-?\d+').stringMatch(value) ?? '');
  if (number == null) return 'Not a number: the default is used';
  final ok = switch (index) {
    < 4 => allowedGains.contains(number),
    4 => allowedRates.contains(number),
    5 => number >= 1 && number <= 4,
    6 || 7 => number >= 1 && number <= 255,
    _ => number == 0 || number == 1,
  };
  if (ok) return null;
  return switch (index) {
    < 4 => 'Gains must be one of ${allowedGains.join(', ')}',
    4 => 'Sample rate must be one of ${allowedRates.join(', ')}',
    5 => 'gps_mode must be 1-4',
    6 || 7 => 'Must be 1-255',
    _ => 'Must be 0 or 1',
  };
}

/// The settings the Check tab's editor changes, and the startup commands that set them. Empty codes mean "the
/// default": no network or location code, the serial number as the station code, and channel codes that follow the
/// sample rate.
class ConfigValues {
  ConfigValues({
    required this.gains,
    required this.sampleRate,
    required this.gpsMode,
    required this.gpsCycleMinutes,
    required this.gpsQuota,
    this.network = '',
    this.station = '',
    this.location = '',
    List<String>? channels,
  }) : channels = channels ?? ['', '', '', ''];

  List<int> gains;
  int sampleRate;
  int gpsMode;
  int gpsCycleMinutes;
  int gpsQuota;
  String network;
  String station;
  String location;
  List<String> channels;

  /// The logger's settings from its startup report, with codes that equal their defaults shown as defaults.
  factory ConfigValues.fromReport(LoggerSettings s, {int? serialNumber}) {
    final defaultStation = serialNumber == null ? null : (serialNumber % 100000).toString().padLeft(5, '0');
    return ConfigValues(
      gains: List.of(s.gains),
      sampleRate: s.sampleRate,
      gpsMode: s.gpsMode,
      gpsCycleMinutes: s.gpsCycleMinutes,
      gpsQuota: s.gpsQuota,
      network: s.network,
      station: s.station == defaultStation ? '' : s.station,
      location: s.location,
      channels: [
        for (var i = 0; i < 4; i++) s.channels[i] == BootReport.defaultChannelCode(i, s.sampleRate) ? '' : s.channels[i],
      ],
    );
  }

  /// Problems that would make the logger reject a value; empty if there are none.
  List<String> problems() {
    final out = <String>[];
    for (var i = 0; i < 4; i++) {
      if (!allowedGains.contains(gains[i])) out.add('Channel ${i + 1} gain must be one of ${allowedGains.join(', ')}');
    }
    if (gains.every((g) => g == 0)) out.add('At least one channel must be on (gain above 0)');
    if (!allowedRates.contains(sampleRate)) out.add('Sample rate must be one of ${allowedRates.join(', ')}');
    if (gpsMode < 1 || gpsMode > 4) out.add('GPS mode must be 1-4');
    if (gpsCycleMinutes < 1 || gpsCycleMinutes > 255) out.add('GPS cycle must be 1-255 minutes');
    if (gpsQuota < 1 || gpsQuota > 255) out.add('GPS quota must be 1-255 fixes');
    void code(String name, String value, int maxLen, {bool exact = false}) {
      if (value.isEmpty) return;
      if (!RegExp(r'^[A-Z0-9]+$').hasMatch(value)) {
        out.add('$name code: letters and digits only');
      } else if (exact && value.length != maxLen) {
        out.add('$name code: exactly $maxLen characters (or blank for the default)');
      } else if (value.length > maxLen) {
        out.add('$name code: at most $maxLen characters');
      }
    }

    code('Network', network, 2);
    code('Station', station, 5);
    code('Location', location, 2);
    for (var i = 0; i < 4; i++) {
      code('Channel ${i + 1}', channels[i], 3, exact: true);
    }
    final effective = [for (var i = 0; i < 4; i++) channelCode(i)];
    for (var i = 1; i < 4; i++) {
      for (var j = 0; j < i; j++) {
        if (gains[i] > 0 && gains[j] > 0 && effective[i] == effective[j]) {
          out.add('Channels ${j + 1} and ${i + 1} have the same code ${effective[i]}');
        }
      }
    }
    return out;
  }

  /// The code channel i will use: its own, or the default for the sample rate.
  String channelCode(int i) => channels[i].isEmpty ? BootReport.defaultChannelCode(i, sampleRate) : channels[i];

  /// Startup commands that set these values, in order; the firmware's SVC command then saves them to CONFIG.TXT.
  /// (Each is one of the existing GN:/CF: commands, so they don't depend on the file's format.)
  List<String> commands() {
    String c(String v) => v.isEmpty ? '-' : v;
    return [
      'GN:${gains.join(',')}',
      'CF:sample_rate=$sampleRate',
      'CF:gps_mode=$gpsMode',
      'CF:gps_cycle_minutes=$gpsCycleMinutes',
      'CF:gps_quota=$gpsQuota',
      'CF:network=${c(network)}',
      'CF:station=${c(station)}',
      'CF:location=${c(location)}',
      for (var i = 0; i < 4; i++) 'CF:channel${i + 1}=${c(channels[i])}',
    ];
  }

  /// Differences between these values and what the logger reports after restarting with the saved file; empty if
  /// they all match.
  List<String> differencesFrom(LoggerSettings s, {int? serialNumber}) {
    final out = <String>[];
    if (s.gains.join(',') != gains.join(',')) out.add('gains ${s.gains.join(',')} (wanted ${gains.join(',')})');
    if (s.sampleRate != sampleRate) out.add('sample rate ${s.sampleRate} (wanted $sampleRate)');
    if (s.gpsMode != gpsMode) out.add('gps_mode ${s.gpsMode} (wanted $gpsMode)');
    if (s.gpsCycleMinutes != gpsCycleMinutes) out.add('GPS cycle ${s.gpsCycleMinutes} (wanted $gpsCycleMinutes)');
    if (s.gpsQuota != gpsQuota) out.add('GPS quota ${s.gpsQuota} (wanted $gpsQuota)');
    if (s.network != network) out.add('network "${s.network}" (wanted "$network")');
    if (s.location != location) out.add('location "${s.location}" (wanted "$location")');
    final wantStation =
        station.isNotEmpty ? station : (serialNumber == null ? s.station : (serialNumber % 100000).toString().padLeft(5, '0'));
    if (s.station != wantStation) out.add('station "${s.station}" (wanted "$wantStation")');
    for (var i = 0; i < 4; i++) {
      if (s.channels[i] != channelCode(i)) out.add('channel ${i + 1} code ${s.channels[i]} (wanted ${channelCode(i)})');
    }
    return out;
  }
}
