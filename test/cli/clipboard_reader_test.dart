/// Pasteboard reader tests (issue #276, review major 2): the Linux paste
/// path must treat stdout as RAW BYTES. `Process.run`'s default text-mode
/// decoding (UTF-8) mangles image payloads — replacement chars where the
/// magic bytes should be — so the reader runs its processes through a
/// binary pipe and the glue must not re-decode.
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/clipboard_reader.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:test/test.dart';

/// A PNG signature followed by NON-UTF8 bytes (0xFF 0xFE): any text-mode
/// decode round-trip replaces them and the equality below fails.
final _pngish = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0xFF, 0xFE, 0x42,
];

ProcessResult _ok(List<int> stdout) => ProcessResult(1, 0, stdout, null);

void main() {
  test('the Linux path hands the raw bytes through untouched', () async {
    Future<ProcessResult> runner(String executable, List<String> args) async =>
        _ok(_pngish);
    final read = await readPasteboardImage(runner: runner);
    expect(read, isA<PasteboardImage>());
    expect((read as PasteboardImage).bytes, _pngish);
  });

  test('a failing first backend falls through to the next one', () async {
    var calls = 0;
    Future<ProcessResult> runner(String executable, List<String> args) async {
      calls++;
      return calls == 1 ? ProcessResult(1, 1, '', 'nope') : _ok(_pngish);
    }

    final read = await readPasteboardImage(runner: runner);
    expect(calls, 2, reason: 'xclip failed → wl-paste tried');
    expect((read as PasteboardImage).bytes, _pngish);
  });

  test('no backend reachable names the failure (edge E1 shape)', () async {
    Future<ProcessResult> runner(String executable, List<String> args) async =>
        ProcessResult(1, 1, '', 'not found');
    final read = await readPasteboardImage(runner: runner);
    expect(read, isA<PasteboardUnavailable>());
    expect((read as PasteboardUnavailable).reason, contains('xclip'));
  });

  test('the real binary pipe neither throws nor mangles', () async {
    // Without xclip/wl-paste installed this lands on the unavailable
    // path — the assertion is that the default binary runner completes
    // cleanly and returns bytes (or the named unavailable), never a
    // decoded String.
    final read = await readPasteboardImage(environment: const {});
    expect(read, anyOf(isA<PasteboardUnavailable>(), isA<PasteboardImage>()));
  }, skip: !Platform.isLinux);

  test('FA_FAKE_PASTEBOARD short-circuits to a file read', () async {
    final dir = await Directory.systemTemp.createTemp('fa_pasteboard');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/fake.png')..writeAsBytesSync(_pngish);
    final read = await readPasteboardImage(
      environment: {'FA_FAKE_PASTEBOARD': file.path},
    );
    expect((read as PasteboardImage).bytes, _pngish);
  });
}
