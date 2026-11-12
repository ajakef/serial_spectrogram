import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/boot_report.dart';
import 'package:serial_spectrogram/config_file.dart';

// The CONFIG.TXT line checker and the editor's settings model.
void main() {
  // The CONFIG.TXT in aspen-firmware (1.0.0-1).
  const repoFile = '''128 # channel 1 gain
64 # channel 2 gain
64 # channel 3 gain
64 # channel 4 gain
400 # sample rate (100, 200, 400, 800, or 1000 samples per second)
1 # gps_mode (1 cycled, 2 always on, 3 off, 4 cycled, with the cycle adjusted to keep timing errors small)
30 # gps_cycle_minutes
20 # gps_quota
1 # use_compression (no longer affects the card's files, but keep this line so the lines below are read in order)
- # network code (2 characters at most; - means blank)
- # station code (5 characters at most; - means the serial number)
- # location code (2 characters at most; - means blank)
- # channel 1 code (3 characters; - means HDF at 100-200 sps, CDF at 400-800, FDF at 1000)
- # channel 2 code (3 characters; - means EHZ at 100-200 sps, DHZ at 400-800, GHZ at 1000)
- # channel 3 code (3 characters; - means EHN, DHN, or GHN, as for channel 2)
- # channel 4 code (3 characters; - means EHE, DHE, or GHE, as for channel 2)
''';

  List<String> problems(String text) => [
        for (final n in checkConfigFile(text)!)
          if (n.problem != null) '${n.lineNumber}: ${n.problem}',
      ];

  test('the standard file has no problems, and each line is read as its setting', () {
    final notes = checkConfigFile(repoFile)!;
    expect(problems(repoFile), isEmpty);
    expect(notes.map((n) => n.setting), configSettingNames);
  });

  test('a missing line is caught where the comments stop matching', () {
    final lines = repoFile.split('\n')..removeAt(6); // gps_cycle_minutes
    final p = problems(lines.join('\n'));
    expect(p.first, startsWith('7: Read as gps_cycle_minutes, but its comment says gps_quota'));
  });

  test('bad values, extra lines, and comment-only lines', () {
    final text = '# my settings\n\n${repoFile.replaceFirst('400 #', '300 #').replaceFirst('- # network', 'X-1 # network')}'
        'EXTRA\n';
    final p = problems(text);
    expect(p, contains('7: Sample rate must be one of 100, 200, 400, 800, 1000'));
    expect(p, contains('12: Codes may hold only letters and digits ("-" for the default)'));
    expect(p.last, startsWith('19: Extra line'));
  });

  test('a short file says which settings take defaults', () {
    final p = problems('128\n0\n0\n0\n200\n');
    expect(p.single, contains('gps_mode, gps_cycle_minutes, gps_quota, use_compression use defaults'));
  });

  test('a file of name=value lines is left alone', () {
    expect(checkConfigFile('sample_rate=200\n'), isNull);
  });

  final reported = LoggerSettings.parse('Config: gains 128,64,64,64; 400 sps; gps_mode 1, cycle 30 min, quota 20, '
      'settle 20 s; compression on; SEED codes XP.00002..CDF.DHZ.DHN.XYZ; files 1440 min')!;

  test('editor values from the logger: codes equal to their defaults are shown as defaults', () {
    final v = ConfigValues.fromReport(reported, serialNumber: 2);
    expect(v.network, 'XP');
    expect(v.station, ''); // the serial number
    expect(v.channels, ['', '', '', 'XYZ']);
    expect(v.problems(), isEmpty);
    expect(v.commands(), [
      'GN:128,64,64,64',
      'CF:sample_rate=400',
      'CF:gps_mode=1',
      'CF:gps_cycle_minutes=30',
      'CF:gps_quota=20',
      'CF:network=XP',
      'CF:station=-',
      'CF:location=-',
      'CF:channel1=-',
      'CF:channel2=-',
      'CF:channel3=-',
      'CF:channel4=XYZ',
    ]);
    expect(v.differencesFrom(reported, serialNumber: 2), isEmpty);
  });

  test('the editor catches what the logger would reject', () {
    final v = ConfigValues.fromReport(reported, serialNumber: 2)
      ..channels[1] = 'DH'
      ..channels[3] = 'CDF'
      ..gpsQuota = 0;
    expect(v.problems(), [
      'GPS quota must be 1-255 fixes',
      'Channel 2 code: exactly 3 characters (or blank for the default)',
      'Channels 1 and 4 have the same code CDF',
    ]);
    final off = ConfigValues.fromReport(reported)..gains = [0, 0, 0, 0];
    expect(off.problems(), contains('At least one channel must be on (gain above 0)'));
  });

  test('differences after saving are reported', () {
    final v = ConfigValues.fromReport(reported, serialNumber: 2)..sampleRate = 200;
    expect(v.differencesFrom(reported, serialNumber: 2), [
      'sample rate 400 (wanted 200)',
      'channel 1 code CDF (wanted HDF)',
      'channel 2 code DHZ (wanted EHZ)',
      'channel 3 code DHN (wanted EHN)',
    ]);
  });
}
