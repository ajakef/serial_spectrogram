import 'dart:math';
import 'dart:typed_data';

/// What the uploader needs from the USB connection (SerialLink provides it; tests use a pretend one).
abstract class SvlPort {
  Future<void> writeBytes(List<int> bytes);

  /// Exactly [count] bytes, or null if they don't all arrive within [timeout].
  Future<Uint8List?> readBytes(int count, Duration timeout);

  /// Throws away anything received but not yet read.
  void clearInput();

  Future<void> setBaud(int baud);

  /// true pulls the RTS pin low (the FTDI cable's RTS is active-low).
  Future<void> setRts(bool asserted);
}

class SvlException implements Exception {
  SvlException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Loads a program into an Artemis board running the SparkFun Variable Loader (SVL) bootloader.
/// A port of svl.py from the SparkFun Arduino core, which is what the Arduino IDE uses.
class SvlUploader {
  SvlUploader(this.port);

  static const baud = 115200;
  static const _cmdBootload = 0x02;
  static const _cmdNext = 0x03;
  static const _cmdFrame = 0x04;
  static const _cmdRetry = 0x05;
  static const _cmdDone = 0x06;
  static const _frameSize = 512 * 4;
  static const _maxResends = 4;

  /// Ways to restart the board, one per attempt, as (how long RTS stays asserted before being released,
  /// or null to leave it asserted; wait before sending 'U'). The Aspen's RTS reset looks edge-triggered,
  /// restarting it the moment RTS is asserted, so the first plan counts the wait from that moment, as svl.py
  /// does. The bootloader only listens for 'U' for a short time after a restart. The other plans cover a
  /// level-triggered reset and slightly different timing.
  static const _resetPlans = <(int?, int)>[(null, 150), (100, 150), (null, 110), (null, 220)];
  static const _timeout = Duration(milliseconds: 500);

  /// Apollo3 flash is 1 MB and programs start 64 kB in.
  static const maxProgramSize = 1024 * 1024 - 0x10000;

  /// A program image starts with the initial stack pointer, which for this board points into its RAM
  /// (0x1000xxxx). Catches picking the wrong file, such as a .hex or .zip, before anything is sent.
  static bool looksLikeProgram(Uint8List bytes) => bytes.length >= 8 && bytes[3] == 0x10;

  final SvlPort port;

  /// Sends [program] to the board. [onProgress] gets 0..1. Throws SvlException on failure.
  Future<void> upload(Uint8List program, {void Function(double)? onProgress, void Function(String)? onStatus}) async {
    if (program.isEmpty) throw SvlException('The firmware file is empty.');
    if (program.length > maxProgramSize) throw SvlException('The firmware file is too big for the board.');
    var enteredBootloader = false;
    for (var attempt = 1; attempt <= _resetPlans.length; attempt++) {
      onStatus?.call(attempt == 1 ? 'Resetting the Aspen...' : 'Trying again ($attempt of ${_resetPlans.length})...');
      onProgress?.call(0);
      await _reset(_resetPlans[attempt - 1]);
      if (!await _enterBootloader()) continue;
      enteredBootloader = true;
      onStatus?.call('Uploading...');
      if (await _sendProgram(program, onProgress)) return;
    }
    throw SvlException(enteredBootloader
        ? 'The upload failed partway. The Aspen is still waiting for firmware, so try again.'
        : 'The Aspen did not respond. Check the cable and that the Aspen is powered, then try again.');
  }

  /// Restarts the board, then waits for its bootloader to start (svl.py waits 0.15 s).
  Future<void> _reset((int?, int) plan) async {
    final (hold, wait) = plan;
    await port.setBaud(baud);
    await port.setRts(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await port.setRts(true);
    if (hold != null) {
      await Future<void>.delayed(Duration(milliseconds: hold));
      await port.setRts(false);
    }
    await Future<void>.delayed(Duration(milliseconds: wait));
  }

  /// Pulses RTS: released, held for 100 ms, released.
  static Future<void> pulseReset(SvlPort port) async {
    await port.setRts(false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await port.setRts(true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await port.setRts(false);
  }

  Future<bool> _enterBootloader() async {
    port.clearInput();
    await port.writeBytes([0x55]); // 'U': lets the board measure the baud rate
    final version = await _readPacket();
    if (version == null) return false;
    await _sendPacket(_cmdBootload, const []);
    return true;
  }

  Future<bool> _sendProgram(Uint8List program, void Function(double)? onProgress) async {
    final totalFrames = (program.length / _frameSize).ceil();
    var frame = 0;
    var resends = 0;
    while (true) {
      final packet = await _readPacket();
      if (packet == null) return false;
      if (packet.cmd == _cmdNext) {
        frame++;
        resends = 0;
      } else if (packet.cmd == _cmdRetry) {
        if (++resends >= _maxResends) return false;
      } else {
        return false;
      }
      if (frame <= totalFrames) {
        final start = (frame - 1) * _frameSize;
        await _sendPacket(_cmdFrame, program.sublist(start, min(start + _frameSize, program.length)));
        onProgress?.call(frame / totalFrames);
      } else {
        await _sendPacket(_cmdDone, const []);
        return true;
      }
    }
  }

  /// Packet layout: 2-byte length, command byte, data, 2-byte checksum (length counts command to checksum).
  Future<_Packet?> _readPacket() async {
    final lengthBytes = await port.readBytes(2, _timeout);
    if (lengthBytes == null) return null;
    final length = (lengthBytes[0] << 8) | lengthBytes[1];
    if (length < 3) return null;
    final payload = await port.readBytes(length, _timeout);
    if (payload == null || crc16(payload) != 0) return null;
    return _Packet(payload[0], payload.sublist(1, length - 2));
  }

  Future<void> _sendPacket(int cmd, List<int> data) {
    final length = 3 + data.length;
    final message = Uint8List(2 + length);
    message[0] = length >> 8;
    message[1] = length & 0xFF;
    message[2] = cmd;
    message.setRange(3, 3 + data.length, data);
    final crc = crc16(message.sublist(2, 3 + data.length));
    message[3 + data.length] = crc >> 8;
    message[4 + data.length] = crc & 0xFF;
    return port.writeBytes(message);
  }

  static final List<int> _crcTable = List.generate(256, (byte) {
    var value = byte << 8;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 0x8000) != 0 ? ((value << 1) ^ 0x8005) & 0xFFFF : (value << 1) & 0xFFFF;
    }
    return value;
  });

  /// CRC-16 with polynomial 0x8005, as in the bootloader. Over data that ends with its own CRC, gives 0.
  static int crc16(List<int> data) {
    var crc = 0;
    for (final byte in data) {
      crc = (_crcTable[byte ^ (crc >> 8)] ^ (crc << 8)) & 0xFFFF;
    }
    return crc;
  }
}

class _Packet {
  _Packet(this.cmd, this.data);
  final int cmd;
  final Uint8List data;
}
