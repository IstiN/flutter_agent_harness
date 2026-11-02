/// gh-2040 — the macOS pasteboard read must ride the native `fa-clip`
/// helper (NSPasteboard, no Apple Events), never `osascript` (the
/// AppleScript transport behind the recurring TCC «access data from other
/// apps» dialog).
///
/// The helper protocol is pinned here on the injected runner seam:
/// `fa-clip <png|jpeg|tiff>` — exit 0 prints the flavor's bytes on stdout,
/// exit 2 means the pasteboard holds no data of that flavor (the Dart-side
/// flavor ladder falls through), anything else is a named transport
/// failure. A missing helper degrades to the named unavailable path with a
/// one-line diagnostic naming the transport.
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/clipboard_reader.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:test/test.dart';

final _pngish = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0xFF, 0xFE, 0x42,
];

ProcessResult _ok(List<int> stdout) => ProcessResult(1, 0, stdout, null);

void main() {
  // A real (empty) file stands in for the compiled helper: the reader
  // checks the helper exists before spawning, so scripted paths must be
  // present on disk. Protocol behavior is pinned on the runner seam.
  String helper = '';
  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('fa_clip_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    helper = '${dir.path}/fa-clip';
    File(helper).writeAsBytesSync(const []);
  });

  group('gh-2040: the macOS read uses the fa-clip transport', () {
    test('the image probe never shells out to osascript', () async {
      final exes = <String>[];
      Future<ProcessResult> runner(String exe, List<String> args) async {
        exes.add(exe);
        return ProcessResult(1, 2, '', 'no flavor'); // every flavor absent
      }

      await readPasteboardImage(
        runner: runner,
        platform: 'macos',
        helperPath: helper,
      );
      expect(
        exes,
        everyElement(isNot('osascript')),
        reason:
            'gh-2040: the AppleScript transport is the TCC dialog — '
            'the probe must never launch osascript again',
      );
    });

    test(
      'the probe walks the helper flavor ladder png → jpeg → tiff',
      () async {
        final calls = <(String, List<String>)>[];
        Future<ProcessResult> runner(String exe, List<String> args) async {
          calls.add((exe, args));
          return ProcessResult(1, 2, '', 'no flavor'); // flavor absent
        }

        final read = await readPasteboardImage(
          runner: runner,
          platform: 'macos',
          helperPath: helper,
        );
        expect(calls, hasLength(3));
        expect(calls.map((c) => c.$1), everyElement(helper));
        expect(calls.map((c) => c.$2).toList(), [
          ['png'],
          ['jpeg'],
          ['tiff'],
        ]);
        expect(read, isA<PasteboardUnavailable>());
        expect((read as PasteboardUnavailable).reason, contains('no image'));
      },
    );

    test('a png-flavor hit returns the raw bytes untouched', () async {
      Future<ProcessResult> runner(String exe, List<String> args) async {
        expect(exe, endsWith('fa-clip'));
        expect(args, ['png']);
        return _ok(_pngish);
      }

      final read = await readPasteboardImage(
        runner: runner,
        platform: 'macos',
        helperPath: helper,
      );
      expect(read, isA<PasteboardImage>());
      expect((read as PasteboardImage).bytes, _pngish);
    });

    test('a jpeg hit on a png-less pasteboard skips the rest', () async {
      final calls = <(String, List<String>)>[];
      Future<ProcessResult> runner(String exe, List<String> args) async {
        calls.add((exe, args));
        return calls.length == 1
            ? ProcessResult(1, 2, '', 'no flavor')
            : _ok(_pngish);
      }

      final read = await readPasteboardImage(
        runner: runner,
        platform: 'macos',
        helperPath: helper,
      );
      expect(calls, hasLength(2), reason: 'png absent → jpeg hit, tiff never');
      expect(calls[1].$2, ['jpeg']);
      expect((read as PasteboardImage).bytes, _pngish);
    });
  });

  group('gh-2040: fa-clip failure shapes degrade to named unavailable', () {
    test(
      'a missing helper names the transport and the expected location',
      () async {
        var calls = 0;
        Future<ProcessResult> runner(String exe, List<String> args) async {
          calls++;
          return _ok(_pngish);
        }

        final read = await readPasteboardImage(
          runner: runner,
          platform: 'macos',
          helperPath: '/opt/fa/bin/missing-fa-clip',
        );
        expect(calls, 0, reason: 'a missing helper must not be executed');
        expect(read, isA<PasteboardUnavailable>());
        final reason = (read as PasteboardUnavailable).reason;
        expect(reason, contains('fa-clip'));
        expect(reason, contains('/opt/fa/bin/missing-fa-clip'));
      },
    );

    test('a crashing helper surfaces the transport failure by name', () async {
      Future<ProcessResult> runner(String exe, List<String> args) async =>
          ProcessResult(1, 1, <int>[], 'Killed: 9'); // quarantined shape
      final read = await readPasteboardImage(
        runner: runner,
        platform: 'macos',
        helperPath: helper,
      );
      expect(read, isA<PasteboardUnavailable>());
      final reason = (read as PasteboardUnavailable).reason;
      expect(reason, contains('fa-clip'));
      expect(reason, contains('Killed: 9'));
    });

    test(
      'a helper dying mid-ladder does not reach the sips conversion',
      () async {
        final exes = <String>[];
        Future<ProcessResult> runner(String exe, List<String> args) async {
          exes.add(exe);
          return ProcessResult(1, 1, <int>[], 'exec format error');
        }

        final read = await readPasteboardImage(
          runner: runner,
          platform: 'macos',
          helperPath: helper,
        );
        expect(
          exes,
          everyElement(endsWith('fa-clip')),
          reason: 'a broken transport aborts before the sips conversion',
        );
        expect(read, isA<PasteboardUnavailable>());
      },
    );
  });

  group('gh-2040: the TIFF ladder keeps the gh-1575 sips conversion', () {
    test('a tiff-only pasteboard converts to PNG via sips', () async {
      const tiff = <int>[0x4D, 0x4D, 0x00, 0x2A, 0xDE, 0xAD];
      Future<ProcessResult> runner(String exe, List<String> args) async {
        if (exe.endsWith('fa-clip')) {
          return args.single == 'tiff'
              ? _ok(tiff)
              : ProcessResult(1, 2, '', '');
        }
        expect(exe, 'sips');
        expect(args.take(3), ['-s', 'format', 'png']);
        final out = args[args.indexOf('--out') + 1];
        File(out).writeAsBytesSync(_pngish);
        return _ok(const []);
      }

      final read = await readPasteboardImage(
        runner: runner,
        platform: 'macos',
        helperPath: helper,
      );
      expect(read, isA<PasteboardImage>());
      expect((read as PasteboardImage).bytes, _pngish);
    });

    test('a failing tiff→png conversion stays a named unavailable', () async {
      Future<ProcessResult> runner(String exe, List<String> args) async {
        if (exe.endsWith('fa-clip')) {
          return args.single == 'tiff'
              ? _ok(const [1, 2, 3, 4])
              : ProcessResult(1, 2, '', '');
        }
        return ProcessResult(1, 1, '', 'sips failed');
      }

      final read = await readPasteboardImage(
        runner: runner,
        platform: 'macos',
        helperPath: helper,
      );
      expect(read, isA<PasteboardUnavailable>());
      expect((read as PasteboardUnavailable).reason, contains('no image'));
    });
  });

  group('gh-2040: transport gates (REG, CI)', () {
    test('AC1 — osascript is absent from the clipboard read path '
        '(bin/ + lib/src/cli/)', () {
      final offenders = <String>[];
      for (final dir in ['lib/src/cli', 'bin']) {
        for (final entity in Directory(dir).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          if (entity.readAsStringSync().contains('osascript')) {
            offenders.add(entity.path);
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'gh-2040 AC1: the AppleScript clipboard transport is gone — '
            'these files still reference osascript',
      );
    });

    test('AC7 — the fa-clip helper source carries no AppleScript surface', () {
      final source = File('tools/fa-clip/fa-clip.swift').readAsStringSync();
      for (final banned in [
        'osascript',
        'AppleScript',
        'NSAppleScript',
        'NSAppleEvent',
        'NSUserAppleScript',
        'kAE',
      ]) {
        expect(
          source,
          isNot(contains(banned)),
          reason:
              'fa-clip must stay a plain NSPasteboard reader (AC7): '
              'found "$banned" in tools/fa-clip/fa-clip.swift',
        );
      }
    });
  });
}
