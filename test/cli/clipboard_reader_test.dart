/// Pasteboard reader tests (issue #276, review major 2): the Linux paste
/// path must treat stdout as RAW BYTES. `Process.run`'s default text-mode
/// decoding (UTF-8) mangles image payloads — replacement chars where the
/// magic bytes should be — so the reader runs its processes through a
/// binary pipe and the glue must not re-decode.
library;

import 'dart:convert';
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
    final read = await readPasteboardImage(runner: runner, platform: 'linux');
    expect(read, isA<PasteboardImage>());
    expect((read as PasteboardImage).bytes, _pngish);
  });

  test('a failing first backend falls through to the next one', () async {
    var calls = 0;
    Future<ProcessResult> runner(String executable, List<String> args) async {
      calls++;
      return calls == 1 ? ProcessResult(1, 1, '', 'nope') : _ok(_pngish);
    }

    final read = await readPasteboardImage(runner: runner, platform: 'linux');
    expect(calls, 2, reason: 'xclip failed → wl-paste tried');
    expect((read as PasteboardImage).bytes, _pngish);
  });

  test('no backend reachable names the failure (edge E1 shape)', () async {
    Future<ProcessResult> runner(String executable, List<String> args) async =>
        ProcessResult(1, 1, '', 'not found');
    final read = await readPasteboardImage(runner: runner, platform: 'linux');
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

  test('the macOS path reads the scratch file the script wrote', () async {
    Future<ProcessResult> runner(String exe, List<String> args) async {
      expect(exe, 'osascript');
      // The script embeds the target path: the fake osascript honors it
      // exactly like the real one — write the image, exit 0.
      final script = args.join(' ');
      final match = RegExp(r'POSIX file "([^"]+)"').firstMatch(script)!;
      File(match.group(1)!).writeAsBytesSync(_pngish);
      return _ok(const []);
    }

    final read = await readPasteboardImage(runner: runner, platform: 'macos');
    expect(read, isA<PasteboardImage>());
    expect((read as PasteboardImage).bytes, _pngish);
  });

  test(
    'the macOS path falls through PNG to JPEG to TIFF, then gives up',
    () async {
      var calls = 0;
      Future<ProcessResult> runner(String exe, List<String> args) async {
        calls++;
        return ProcessResult(1, 1, '', 'clipboard holds no image');
      }

      final read = await readPasteboardImage(runner: runner, platform: 'macos');
      expect(calls, 3, reason: 'PNGf tried, then JPEG, then the TIFF fallback');
      expect(read, isA<PasteboardUnavailable>());
    },
  );

  // --- gh-1575: a TIFF-only pasteboard (Preview, browsers) must paste ---

  test('a TIFF-only macOS pasteboard converts to PNG via sips', () async {
    const tiff = <int>[0x4D, 0x4D, 0x00, 0x2A, 0xDE, 0xAD];
    final png = _pngish;
    Future<ProcessResult> runner(String exe, List<String> args) async {
      final script = args.join(' ');
      if (exe == 'osascript') {
        if (!script.contains('«class TIFF»')) {
          return ProcessResult(1, 1, '', 'no image of this class');
        }
        final match = RegExp(r'POSIX file "([^"]+)"').firstMatch(script)!;
        File(match.group(1)!).writeAsBytesSync(tiff);
        return _ok(const []);
      }
      expect(exe, 'sips');
      expect(args.take(3), ['-s', 'format', 'png']);
      final out = args[args.indexOf('--out') + 1];
      File(out).writeAsBytesSync(png);
      return _ok(const []);
    }

    final read = await readPasteboardImage(runner: runner, platform: 'macos');
    expect(read, isA<PasteboardImage>());
    expect((read as PasteboardImage).bytes, png);
  });

  test('a failing TIFF→PNG conversion falls through to unavailable', () async {
    Future<ProcessResult> runner(String exe, List<String> args) async {
      final script = args.join(' ');
      if (exe == 'osascript') {
        if (!script.contains('«class TIFF»')) {
          return ProcessResult(1, 1, '', 'no image of this class');
        }
        final match = RegExp(r'POSIX file "([^"]+)"').firstMatch(script)!;
        File(match.group(1)!).writeAsBytesSync(const [1, 2, 3, 4]);
        return _ok(const []);
      }
      return ProcessResult(1, 1, '', 'sips failed'); // conversion breaks
    }

    final read = await readPasteboardImage(runner: runner, platform: 'macos');
    expect(read, isA<PasteboardUnavailable>());
    expect((read as PasteboardUnavailable).reason, contains('no image'));
  });

  // --- gh-1575: readPasteboardText — the Ctrl+V text fallback ---

  test('the macOS text path reads pbpaste', () async {
    Future<ProcessResult> runner(String exe, List<String> args) async {
      expect(exe, 'pbpaste');
      return _ok(utf8.encode('hello clipboard'));
    }

    final read = await readPasteboardText(runner: runner, platform: 'macos');
    expect(read, isA<PasteboardText>());
    expect((read as PasteboardText).text, 'hello clipboard');
  });

  test('an empty pbpaste result is a named unavailable', () async {
    Future<ProcessResult> runner(String exe, List<String> args) async =>
        _ok(const []);
    final read = await readPasteboardText(runner: runner, platform: 'macos');
    expect(read, isA<PasteboardUnavailable>());
  });

  test('the Linux text path falls back from xclip to wl-paste', () async {
    var calls = 0;
    Future<ProcessResult> runner(String exe, List<String> args) async {
      calls++;
      return calls == 1
          ? ProcessResult(1, 1, '', 'nope')
          : _ok(utf8.encode('wayland text'));
    }

    final read = await readPasteboardText(runner: runner, platform: 'linux');
    expect(calls, 2, reason: 'xclip failed → wl-paste tried');
    expect((read as PasteboardText).text, 'wayland text');
  });

  test('the Windows text path strips the one PowerShell newline', () async {
    Future<ProcessResult> runner(String exe, List<String> args) async {
      expect(exe, 'powershell');
      return _ok(utf8.encode('windows text\r\n'));
    }

    final read = await readPasteboardText(runner: runner, platform: 'windows');
    expect((read as PasteboardText).text, 'windows text');
  });

  test('no text backend reachable names the failure', () async {
    Future<ProcessResult> runner(String exe, List<String> args) async =>
        ProcessResult(1, 1, '', 'not found');
    final read = await readPasteboardText(runner: runner, platform: 'linux');
    expect(read, isA<PasteboardUnavailable>());
    expect((read as PasteboardUnavailable).reason, contains('xclip'));
  });

  // --- gh-1575 review: the text backends must be encoding- and type-pinned ---

  test('the Windows text command pins UTF-8 on the console encoding', () async {
    String? command;
    Future<ProcessResult> runner(String exe, List<String> args) async {
      expect(exe, 'powershell');
      command = args.last;
      return _ok(utf8.encode('windows text\r\n'));
    }

    await readPasteboardText(runner: runner, platform: 'windows');
    // Windows PowerShell 5.1 writes redirected stdout in the OEM code
    // page; without this pin every non-ASCII clipboard character lands
    // in the composer as U+FFFD (review important 2).
    expect(
      command,
      contains('[Console]::OutputEncoding=[System.Text.Encoding]::UTF8'),
    );
    expect(command, contains('Get-Clipboard'));
  });

  test('the Windows text path normalizes embedded CRLF to LF', () async {
    Future<ProcessResult> runner(String exe, List<String> args) async =>
        _ok(utf8.encode('line one\r\nline two\r\n'));

    final read = await readPasteboardText(runner: runner, platform: 'windows');
    // Get-Clipboard formats every line with \r\n — the composer must see
    // the same text the clipboard held, not a \r-riddled one (review
    // important 2, secondary).
    expect((read as PasteboardText).text, 'line one\nline two');
  });

  test('the Linux text backends pin the text content type', () async {
    final calls = <(String, List<String>)>[];
    Future<ProcessResult> runner(String exe, List<String> args) async {
      calls.add((exe, args));
      return calls.length == 1
          ? ProcessResult(1, 1, '', 'nope')
          : _ok(utf8.encode('wayland text'));
    }

    final read = await readPasteboardText(runner: runner, platform: 'linux');
    expect(read, isA<PasteboardText>());
    expect(calls, hasLength(2));
    final (xclipExe, xclipArgs) = calls[0];
    final (wlExe, wlArgs) = calls[1];
    expect(xclipExe, 'xclip');
    // Unpinned xclip defaults to STRING; wl-paste without --type pastes
    // the FIRST MIME the source offers — for an image-only clipboard the
    // raw image bytes, which used to reach the composer as "text"
    // (review important 3). Pinned, both fail cleanly instead.
    expect(xclipArgs, containsAll(['-t', 'text/plain;charset=utf-8']));
    expect(wlExe, 'wl-paste');
    expect(wlArgs, containsAllInOrder(['--type', 'text/plain;charset=utf-8']));
  });

  test(
    'an image-only Linux clipboard is not dumped into the composer',
    () async {
      // With the type pin, a clipboard holding only image MIME fails both
      // backends (exit 1) — the named reason, never decoded image bytes.
      Future<ProcessResult> runner(String exe, List<String> args) async =>
          ProcessResult(1, 1, const <int>[], 'target not available');

      final read = await readPasteboardText(runner: runner, platform: 'linux');
      expect(read, isA<PasteboardUnavailable>());
      expect((read as PasteboardUnavailable).reason, contains('xclip'));
    },
  );

  test('the pinned platform falls through to the platform note', () async {
    final read = await readPasteboardImage(
      runner: (exe, args) async => _ok(const []),
      platform: 'plan9',
    );
    expect(
      (read as PasteboardUnavailable).reason,
      contains('no pasteboard reader'),
    );
  });
}
