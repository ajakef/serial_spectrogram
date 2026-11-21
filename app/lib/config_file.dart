import 'aspen_config.dart';
import 'boot_report.dart';

export 'aspen_config.dart' show ConfigLineNote;

// CONFIG.TXT itself is checked by aspen_config.dart, with the firmware's rules. This file holds the Check tab's editor
// model: the settings it changes and the startup commands that set them.

/// The values the editor offers: the firmware's (from its settings table, aspen_config_spec.dart).
final allowedGains = AspenConfigSpec.gains;
final allowedRates = AspenConfigSpec.sampleRates; // 4000: channel 1 only

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

  /// The logger's settings from its startup report, with codes that equal their defaults shown as defaults. Channel
  /// codes that came with their own locations (firmware 1.0.0-32: none set, and infrasound sensors found on channels
  /// 2-4) are defaults too: saving them would set them, the sensor check would stop, and channels 1-4 would then share
  /// one code and location.
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
        for (var i = 0; i < 4; i++)
          s.channelLocations != null || s.channels[i] == BootReport.defaultChannelCode(i, s.sampleRate) ? '' : s.channels[i],
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
    if (sampleRate >= 4000 && gains.skip(1).any((g) => g != 0)) {
      out.add('At 4000 per second only channel 1 records: set the channel 2-4 gains to 0');
    }
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
    // All codes blank, and the logger found infrasound sensors on channels 2-4 (firmware 1.0.0-32): it chose the
    // channel codes itself.
    final bySensors = s.channelLocations != null && location.isEmpty && channels.every((c) => c.isEmpty);
    for (var i = 0; i < 4; i++) {
      if (!bySensors && s.channels[i] != channelCode(i)) {
        out.add('channel ${i + 1} code ${s.channels[i]} (wanted ${channelCode(i)})');
      }
    }
    return out;
  }
}
