// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';
import 'package:fa_ui/fa_ui.dart' show FaClipboardUnsupportedException;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa/services/clipboard_files.dart';
import 'package:fa/services/clipboard_files_io.dart';
import 'package:fa/services/clipboard_uploads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const filesChannel = MethodChannel('fa/clipboard_files');
  const pasteboardChannel = MethodChannel('pasteboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(filesChannel, null);
    messenger.setMockMethodCallHandler(pasteboardChannel, null);
  });

  /// Answers the native channel with [files] (name/bytes maps) and the
  /// [unsupported] flag, recording whether it was consulted at all.
  ({int calls}) answerNative({
    List<Map<String, Object?>> files = const [],
    bool unsupported = false,
    Object? error,
  }) {
    var calls = 0;
    messenger.setMockMethodCallHandler(filesChannel, (call) async {
      calls++;
      if (call.method != 'readClipboardFiles') {
        throw MissingPluginException();
      }
      if (error != null) throw error;
      return {'files': files, 'unsupported': unsupported};
    });
    return (calls: calls);
  }

  void answerPasteboard(Uint8List? bytes) {
    messenger.setMockMethodCallHandler(pasteboardChannel, (call) async {
      if (call.method != 'image') return null;
      return bytes;
    });
  }

  group('readClipboardUploads', () {
    test('stages native file refs first and never consults the image '
        'reader', () async {
      answerNative(
        files: [
          {
            'name': 'report.pdf',
            'bytes': Uint8List.fromList([1, 2, 3]),
          },
          {
            'name': 'take.mp3',
            'bytes': Uint8List.fromList([4]),
          },
        ],
      );
      answerPasteboard(Uint8List.fromList([9, 9, 9]));
      final files = await readClipboardUploads();
      expect(files, hasLength(2));
      expect(files[0].name, 'report.pdf');
      expect(files[0].mimeType, 'application/pdf');
      expect(files[0].bytes, [1, 2, 3]);
      expect(files[1].name, 'take.mp3');
      expect(files[1].mimeType, 'audio/mpeg');
    });

    test(
      'falls through to Pasteboard.image when no files are staged',
      () async {
        answerNative();
        answerPasteboard(Uint8List.fromList([7, 8, 9]));
        final files = await readClipboardUploads();
        expect(files, hasLength(1));
        expect(files.single.name, startsWith('paste-'));
        expect(files.single.name, endsWith('.png'));
        expect(files.single.mimeType, 'image/png');
        expect(files.single.bytes, [7, 8, 9]);
      },
    );

    test('missing native handler degrades to the image path', () async {
      messenger.setMockMethodCallHandler(filesChannel, (call) async {
        throw MissingPluginException();
      });
      answerPasteboard(Uint8List.fromList([5]));
      final files = await readClipboardUploads();
      expect(files, hasLength(1));
      expect(files.single.mimeType, 'image/png');
    });

    test(
      'empty clipboard (nothing stageable, no image) is a silent empty',
      () async {
        answerNative();
        answerPasteboard(null);
        expect(await readClipboardUploads(), isEmpty);
      },
    );

    test('file-shaped-but-unstageable content throws the unsupported hint '
        'instead of silence', () async {
      answerNative(unsupported: true);
      answerPasteboard(null);
      expect(
        readClipboardUploads,
        throwsA(isA<FaClipboardUnsupportedException>()),
      );
    });

    test('channel-level failure stays silent (not a stageable-content '
        'signal)', () async {
      answerNative(error: PlatformException(code: 'oops'));
      answerPasteboard(null);
      expect(await readClipboardUploads(), isEmpty);
    });
  });

  group('readClipboardFiles (channel contract)', () {
    test('malformed entries are skipped, well-formed kept', () async {
      messenger.setMockMethodCallHandler(filesChannel, (call) async {
        return {
          'files': [
            {
              'name': 'keep.txt',
              'bytes': Uint8List.fromList([1]),
            },
            {
              'bytes': Uint8List.fromList([2]),
            }, // no name
            {'name': 'bad-bytes', 'bytes': 'nope'}, // not bytes
            'junk', // not a map
            {'name': 'ok.bin', 'bytes': Uint8List(0)},
          ],
          'unsupported': false,
        };
      });
      final probe = await readClipboardFilesViaChannelForTest();
      expect(probe.files.map((f) => f.name), ['keep.txt', 'ok.bin']);
      expect(probe.unsupported, isFalse);
    });

    test('null answer reads as an empty probe', () async {
      messenger.setMockMethodCallHandler(filesChannel, (call) async => null);
      final probe = await readClipboardFilesViaChannelForTest();
      expect(probe.files, isEmpty);
      expect(probe.unsupported, isFalse);
    });
  });

  group('readClipboardFilesUriList (Linux)', () {
    late Directory scratch;

    setUp(() => scratch = Directory.systemTemp.createTempSync('fah_clip'));
    tearDown(() => scratch.deleteSync(recursive: true));

    File note(String name) {
      final file = File('${scratch.path}/$name');
      file.writeAsBytesSync([name.length, 42]);
      return file;
    }

    test('uri-list entries stage as named files', () async {
      final a = note('a.txt');
      final b = note('b.mp3');
      final probe = await readClipboardFilesUriList(
        runProcess: (_, _) async =>
            ProcessResult(0, 0, 'file://${a.path}\nfile://${b.path}\n', ''),
      );
      expect(probe.files, hasLength(2));
      expect(probe.files[0].name, 'a.txt');
      expect(probe.files[0].bytes, [5, 42]);
      expect(probe.files[1].name, 'b.mp3');
    });

    test('xclip failure falls through to wl-paste', () async {
      final file = note('c.png');
      final seen = <String>[];
      final probe = await readClipboardFilesUriList(
        runProcess: (executable, _) async {
          seen.add(executable);
          if (executable == 'xclip') {
            return ProcessResult(0, 1, '', 'xclip: no display');
          }
          return ProcessResult(0, 0, 'file://${file.path}', '');
        },
      );
      expect(seen, ['xclip', 'wl-paste']);
      expect(probe.files.single.name, 'c.png');
    });

    test('only non-file URIs surface the unsupported flag', () async {
      final probe = await readClipboardFilesUriList(
        runProcess: (_, _) async =>
            ProcessResult(0, 0, 'https://example.com/file.txt\n', ''),
      );
      expect(probe.files, isEmpty);
      expect(probe.unsupported, isTrue);
    });

    test('both CLIs absent is a silent empty', () async {
      final probe = await readClipboardFilesUriList(
        runProcess: (_, _) async => ProcessResult(0, 1, '', 'not found'),
      );
      expect(probe.files, isEmpty);
      expect(probe.unsupported, isFalse);
    });

    test('unplain uri encoding resolves through Uri parsing', () async {
      final dir = Directory.systemTemp.createTempSync('fah clip enc');
      final file = File('${dir.path}/with space.txt');
      file.writeAsBytesSync([1]);
      final encoded = Uri.file(file.path).toString();
      final probe = await readClipboardFilesUriList(
        runProcess: (_, _) async => ProcessResult(0, 0, encoded, ''),
      );
      dir.deleteSync(recursive: true);
      expect(probe.files.single.name, 'with space.txt');
    });
  });

  group('readClipboardFilesWin32 (dispatch guard)', () {
    test('is a silent empty off-Windows (the FFI path itself needs a '
        'Windows device run)', () async {
      final probe = await readClipboardFilesWin32();
      expect(probe.files, isEmpty);
      expect(probe.unsupported, isFalse);
    });
  });
}
