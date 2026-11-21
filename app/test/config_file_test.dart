import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/boot_report.dart';
import 'package:serial_spectrogram/config_file.dart';

// The Check tab editor's settings model.
void main() {
  // (CONFIG.TXT itself is checked by aspen_config.dart: test/aspen_config_test.dart.)
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

  test('codes the logger chose from its sensors (infrasound on channels 2-4) stay defaults', () {
    final bySensors = LoggerSettings.parse('Config: gains 128,32,32,32; 200 sps; gps_mode 1, cycle 30 min, quota 20, '
        'settle 20 s; compression on; SEED codes .00002..HDF.HDF.HDF.HDF; channel locations -,01,02,03; files 1440 min')!;
    expect(bySensors.channelLocations, ['', '01', '02', '03']);
    expect([for (var i = 0; i < 4; i++) bySensors.channelLabel(i)], ['HDF', '01.HDF', '02.HDF', '03.HDF']);
    final v = ConfigValues.fromReport(bySensors, serialNumber: 2);
    expect(v.channels, ['', '', '', '']);
    expect(v.location, '');
    expect(v.commands(), containsAll(['CF:location=-', 'CF:channel2=-', 'CF:channel3=-', 'CF:channel4=-']));
    expect(v.differencesFrom(bySensors, serialNumber: 2), isEmpty);
    // a code set in the editor stops the sensor check, so every channel is compared again
    expect((ConfigValues.fromReport(bySensors)..channels[1] = 'EHZ').differencesFrom(bySensors),
        ['channel 2 code HDF (wanted EHZ)', 'channel 3 code HDF (wanted EHN)', 'channel 4 code HDF (wanted EHE)']);
    expect(BootReport.settingsWarnings(bySensors), isEmpty);  // HDF on channels 2-4 is right for infrasound
    expect(reported.channelLocations, isNull);
    expect(reported.channelLabel(1), 'DHZ');
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
    final fast = ConfigValues.fromReport(reported)..sampleRate = 4000;
    expect(fast.problems(), ['At 4000 per second only channel 1 records: set the channel 2-4 gains to 0']);
    fast.gains = [128, 0, 0, 0];
    expect(fast.problems(), isEmpty);
    expect((ConfigValues.fromReport(reported)..sampleRate = 2000).problems(), isEmpty); // 2000: all four channels
    expect(allowedRates, [100, 200, 400, 800, 1000, 2000, 4000]);
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
