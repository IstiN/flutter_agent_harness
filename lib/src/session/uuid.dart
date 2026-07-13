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

/// Generates a time-ordered UUIDv7 string.
String uuidv7() {
  final randomBytes = Uint8List.fromList([
    for (var i = 0; i < 16; i++) _random.nextInt(256),
  ]);
  final timestamp = DateTime.now().millisecondsSinceEpoch;

  if (timestamp > _lastTimestamp) {
    _sequence =
        (randomBytes[6] << 24) |
        (randomBytes[7] << 16) |
        (randomBytes[8] << 8) |
        randomBytes[9];
    _lastTimestamp = timestamp;
  } else {
    _sequence = (_sequence + 1) & 0xffffffff;
    if (_sequence == 0) _lastTimestamp++;
  }

  final ts = _lastTimestamp;
  final bytes = Uint8List(16);
  bytes[0] = (ts ~/ 0x10000000000) & 0xff;
  bytes[1] = (ts ~/ 0x100000000) & 0xff;
  bytes[2] = (ts ~/ 0x1000000) & 0xff;
  bytes[3] = (ts ~/ 0x10000) & 0xff;
  bytes[4] = (ts ~/ 0x100) & 0xff;
  bytes[5] = ts & 0xff;
  bytes[6] = 0x70 | ((_sequence >> 28) & 0x0f);
  bytes[7] = (_sequence >> 20) & 0xff;
  bytes[8] = 0x80 | ((_sequence >> 14) & 0x3f);
  bytes[9] = (_sequence >> 6) & 0xff;
  bytes[10] = ((_sequence & 0x3f) << 2) | (randomBytes[10] & 0x03);
  bytes[11] = randomBytes[11];
  bytes[12] = randomBytes[12];
  bytes[13] = randomBytes[13];
  bytes[14] = randomBytes[14];
  bytes[15] = randomBytes[15];

  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).toList();
  return '${hex.sublist(0, 4).join()}-'
      '${hex.sublist(4, 6).join()}-'
      '${hex.sublist(6, 8).join()}-'
      '${hex.sublist(8, 10).join()}-'
      '${hex.sublist(10, 16).join()}';
}
