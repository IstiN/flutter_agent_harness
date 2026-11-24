/// UUIDv7 generator used for session and record ids.
///
/// Ported from pi-mono `packages/agent/src/harness/session/uuid.ts`:
/// time-ordered UUIDs so session file names sort chronologically.
library;

import 'dart:math';
import 'dart:typed_data';

final _random = Random.secure();
int _lastTimestamp = -1;
int _sequence = 0;
final _hexDigits = Uint8List.fromList('0123456789abcdef'.codeUnits);
final _uuidChars = Uint8List(36)
  ..[8] = 0x2d
  ..[13] = 0x2d
  ..[18] = 0x2d
  ..[23] = 0x2d;

void _writeHexByte(int offset, int byte) {
  _uuidChars[offset] = _hexDigits[byte >> 4];
  _uuidChars[offset + 1] = _hexDigits[byte & 0x0f];
}

/// Generates a time-ordered UUIDv7 string.
String uuidv7() {
  final timestamp = DateTime.now().millisecondsSinceEpoch;

  if (timestamp > _lastTimestamp) {
    _sequence = (_random.nextInt(0x10000) << 16) | _random.nextInt(0x10000);
    _lastTimestamp = timestamp;
  } else {
    _sequence = (_sequence + 1) & 0xffffffff;
    if (_sequence == 0) _lastTimestamp++;
  }

  final ts = _lastTimestamp;
  final r1 = _random.nextInt(0x10000);
  final r2 = _random.nextInt(0x10000);
  final r3 = _random.nextInt(0x10000);

  _writeHexByte(0, (ts ~/ 0x10000000000) & 0xff);
  _writeHexByte(2, (ts ~/ 0x100000000) & 0xff);
  _writeHexByte(4, (ts ~/ 0x1000000) & 0xff);
  _writeHexByte(6, (ts ~/ 0x10000) & 0xff);
  _writeHexByte(9, (ts ~/ 0x100) & 0xff);
  _writeHexByte(11, ts & 0xff);
  _writeHexByte(14, 0x70 | ((_sequence >> 28) & 0x0f));
  _writeHexByte(16, (_sequence >> 20) & 0xff);
  _writeHexByte(19, 0x80 | ((_sequence >> 14) & 0x3f));
  _writeHexByte(21, (_sequence >> 6) & 0xff);
  _writeHexByte(24, ((_sequence & 0x3f) << 2) | (r1 & 0x03));
  _writeHexByte(26, (r1 >> 8) & 0xff);
  _writeHexByte(28, r2 & 0xff);
  _writeHexByte(30, (r2 >> 8) & 0xff);
  _writeHexByte(32, r3 & 0xff);
  _writeHexByte(34, (r3 >> 8) & 0xff);

  return String.fromCharCodes(_uuidChars);
}
