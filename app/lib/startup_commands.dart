import 'dart:async';

/// Answers the logger's startup prompt: turns off compression (NCM), says no SD card is required (NSD), and sets
/// the gains (GN:).
///
/// Firmware 0.8.2 and later reply "Gains accepted: ..." or "Gains rejected ...". If the gains are
/// rejected (e.g. a byte was garbled on the way), they are sent again; the logger keeps listening.
/// If there's no reply, or the accepted gains aren't the ones sent (a dropped digit can still leave a
/// valid gain), the logger is restarted and setup starts over. Older firmware doesn't reply, so the
/// commands are sent once, as before. Same behavior as serial_spectrogram.py.
class StartupCommands {
  StartupCommands({
    required this.write,
    required this.restart,
    required this.onProblem,
    this.replyTimeout = const Duration(seconds: 3),
  });

  static const gains = '128,32,32,32'; // standard gains
  static const maxSends = 3; // per startup
  static const maxRestarts = 3;

  final void Function(String text) write;
  final Future<void> Function() restart; // restarts the logger, which then prompts again
  final void Function(String message) onProblem; // setup failed after every retry
  final Duration replyTimeout;

  static final _version = RegExp(r'Firmware: (\d+)\.(\d+)\.(\d+)');
  bool _checksGains = false; // the logger's firmware replies to GN:
  bool _awaitingReply = false;
  int _sends = 0;
  int _restarts = 0;
  Timer? _timer;

  /// A new connection: retries start over.
  void reset() {
    _timer?.cancel();
    _awaitingReply = false;
    _restarts = 0;
  }

  void handleLine(String line) {
    final v = _version.firstMatch(line);
    if (v != null) {
      final n = [for (var i = 1; i <= 3; i++) int.parse(v[i]!)];
      _checksGains = n[0] > 0 || n[1] > 8 || (n[1] == 8 && n[2] >= 2);
    }
    if (line == 'Enter Serial Number') {
      write('NCM\r\n'); // command for "no compression"
      write('NSD\r\n'); // "no SD card required": plotting works without a card, and SD errors aren't shown (older firmware ignores it)
      _sends = 0;
      _sendGains();
      return;
    }
    if (!_awaitingReply) return;
    if (line.contains('Gains rejected')) {
      _timer?.cancel();
      if (_sends < maxSends) {
        _sendGains(); // the logger is still listening
      } else {
        _restartLogger('the Aspen rejected them $maxSends times');
      }
    } else if (line.contains('Gains accepted')) {
      _timer?.cancel();
      _awaitingReply = false;
      if (line.split(':').last.trim() == gains) {
        _restarts = 0;
      } else {
        _restartLogger('the Aspen accepted different gains: ${line.split(':').last.trim()}');
      }
    }
  }

  void _sendGains() {
    // the extra blank line tells the logger no more commands are coming, so it skips its wait
    write('GN:$gains\r\n\n');
    if (!_checksGains) return;
    _awaitingReply = true;
    _sends++;
    _timer?.cancel();
    _timer = Timer(replyTimeout, () => _restartLogger('the Aspen did not reply'));
  }

  void _restartLogger(String reason) {
    _timer?.cancel();
    _awaitingReply = false;
    if (_restarts >= maxRestarts) {
      onProblem('Could not set the gains to $gains ($reason)');
      return;
    }
    _restarts++;
    restart();
  }

  void dispose() => _timer?.cancel();
}
