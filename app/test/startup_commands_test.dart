import 'package:flutter_test/flutter_test.dart';
import 'package:serial_spectrogram/sample_rate.dart';
import 'package:serial_spectrogram/startup_commands.dart';

// A pretend logger: records what the app sends and how often it restarts the logger.
class _Harness {
  final sent = <String>[];
  var restarts = 0;
  String? problem;
  late final commands = StartupCommands(
    write: sent.add,
    restart: () async => restarts++,
    onProblem: (m) => problem = m,
    replyTimeout: const Duration(milliseconds: 50),
  );
  int get gainCommands => sent.where((s) => s.startsWith('GN:')).length;

  void boot(String version) {
    commands.handleLine('Firmware: $version');
    commands.handleLine('Pins initialized');
    commands.handleLine('Enter Serial Number');
  }
}

const _ok = 'Gains accepted: 128,32,32,32';
const _rejected = 'Gains rejected ("128,32,3²,32"; send again); keeping 128,64,64,64';
const _wrong = 'Gains accepted: 128,32,2,32';

const _rateOk = 'Config set: sample_rate=200';

void main() {
  test('newer firmware: sets the sample rate first, then the gains', () async {
    final h = _Harness()..boot('1.0.0-1_2026-11-12T06:02:16Z');
    expect(h.sent, ['NCM\r\n', 'NSD\r\n', 'CF:sample_rate=200\r\n']);
    h.commands.handleLine(_rateOk);
    expect(h.sent.last, 'GN:128,32,32,32\r\n\n');
    h.commands.handleLine(_ok);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.restarts, 0);
    expect(h.problem, isNull);
  });

  test('sends the sample rate the user chose, again if rejected, and restarts on a garbled setting', () async {
    SampleRate.current = 800;
    addTearDown(() => SampleRate.current = SampleRate.standard);
    final h = _Harness()..boot('0.8.5-15_x');
    expect(h.sent.last, 'CF:sample_rate=800\r\n');
    h.commands.handleLine('Config rejected; send again: sample_rae=800');
    expect(h.sent.where((s) => s.startsWith('CF:')).length, 2);
    h.commands.handleLine('Config set: sample_rate=80');
    expect(h.restarts, 1);
    expect(h.gainCommands, 0);
  });

  test('firmware without CF: (0.8.6-x, 0.8.5 before build 15) gets only the gains', () {
    for (final v in ['0.8.6-3_x', '0.8.5-14_x']) {
      final h = _Harness()..boot(v);
      expect(h.sent, ['NCM\r\n', 'NSD\r\n', 'GN:128,32,32,32\r\n\n']);
    }
  });

  test('sends NCM and the gains, and is done when they are accepted', () async {
    final h = _Harness()..boot('0.8.2-0_2026-10-18T00:00:00Z');
    expect(h.sent, ['NCM\r\n', 'NSD\r\n', 'GN:128,32,32,32\r\n\n']);
    h.commands.handleLine(_ok);
    await Future<void>.delayed(const Duration(milliseconds: 100)); // past the reply timeout: nothing more happens
    expect(h.gainCommands, 1);
    expect(h.restarts, 0);
  });

  test('sends the gains again when the logger rejects them', () async {
    final h = _Harness()..boot('0.8.2-0_x');
    h.commands.handleLine(_rejected);
    expect(h.gainCommands, 2);
    h.commands.handleLine(_ok);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.restarts, 0);
  });

  test('restarts the logger when it accepts the wrong gains, and starts over', () async {
    final h = _Harness()..boot('0.8.2-0_x');
    h.commands.handleLine(_wrong);
    expect(h.restarts, 1);
    h.boot('0.8.2-0_x'); // the logger restarts and prompts again
    h.commands.handleLine(_ok);
    expect(h.gainCommands, 2);
    expect(h.problem, isNull);
  });

  test('restarts the logger when it does not reply', () async {
    final h = _Harness()..boot('0.8.2-0_x');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.restarts, 1);
  });

  test('older firmware: sends the commands once and waits for nothing', () async {
    final h = _Harness()..boot('0.8.1-0_2026-10-17T04:13:22Z');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.gainCommands, 1);
    expect(h.restarts, 0);
  });

  test('gives up with a message after 3 restarts', () async {
    final h = _Harness()..boot('0.8.2-0_x');
    for (var i = 0; i < 3; i++) {
      h.commands.handleLine(_wrong);
      h.boot('0.8.2-0_x');
    }
    h.commands.handleLine(_wrong);
    expect(h.restarts, 3);
    expect(h.problem, contains('Could not set the gains'));
  });
}
