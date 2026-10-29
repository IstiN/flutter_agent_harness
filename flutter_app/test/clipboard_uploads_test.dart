// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa/services/clipboard_uploads.dart';
import 'package:fa_ui/fa_ui.dart' show FaClipboardUnsupportedException;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_clipboard/super_clipboard.dart';

/// Pins the type-aware clipboard walk (issue #1979 AC3/AC4): copied file
/// references read per item in order, raw flavor priority
/// (audio/video/pdf > images), the `paste-<ts>.<ext>` fallback name, and
/// the unsupported-flavor hint contract (rich clipboard without plain text
/// throws — the composer toasts it, never silence).
void main() {
  group('readClipboardUploads', () {
    test(
      'reads every file-reference item in order (Finder/Explorer copy)',
      () async {
        final dir = await Directory.systemTemp.createTemp('fa_clip_test');
        addTearDown(() => dir.delete(recursive: true));
        final a = File('${dir.path}/notes.txt');
        final b = File('${dir.path}/sheet.csv');
        await a.writeAsString('hello');
        await b.writeAsString('x,y\n1,2');

        final files = await readClipboardUploads(
          source: ClipboardReader([
            _FakeItem(
              values: {Formats.fileUri: Uri.file(a.path)},
              platformFormats: const ['public.file-url'],
            ),
            _FakeItem(
              values: {Formats.fileUri: Uri.file(b.path)},
              platformFormats: const ['public.file-url'],
            ),
          ]),
        );

        expect(files.map((f) => f.name).toList(), ['notes.txt', 'sheet.csv']);
        expect(utf8.decode(files[0].bytes), 'hello');
        expect(utf8.decode(files[1].bytes), 'x,y\n1,2');
        // Names are what the outgoing message references; the MIME table
        // has no .txt/.csv rows yet, so the derived type stays generic.
        expect(files[0].mimeType, 'application/octet-stream');
      },
    );

    test('an audio flavor beats an image flavor and keeps its real name '
        '(files > audio/video > image)', () async {
      final files = await readClipboardUploads(
        source: ClipboardReader([
          _FakeItem(
            advertised: {Formats.mp3, Formats.png},
            files: {
              Formats.mp3: ([9, 9, 9], 'voice memo.mp3'),
              Formats.png: ([1, 2, 3], null),
            },
            platformFormats: const ['public.mp3'],
          ),
        ]),
      );

      expect(files, hasLength(1));
      expect(files.single.name, 'voice memo.mp3');
      expect(files.single.mimeType, 'audio/mpeg');
    });

    test('an image-only clipboard synthesizes paste-<ts>.<ext> with the '
        'derived MIME', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      final files = await readClipboardUploads(
        source: ClipboardReader([
          _FakeItem(
            advertised: {Formats.png},
            files: {
              Formats.png: ([1, 2, 3, 4], null),
            },
            platformFormats: const ['public.png'],
          ),
        ]),
      );

      expect(files, hasLength(1));
      expect(files.single.name, matches(RegExp(r'^paste-\d+\.png$')));
      final stamp = int.parse(files.single.name.split('-')[1].split('.').first);
      expect(stamp, greaterThanOrEqualTo(before));
      expect(files.single.mimeType, 'image/png');
    });

    test('an empty clipboard is a silent no-op', () async {
      final files = await readClipboardUploads(
        source: ClipboardReader(const []),
      );
      expect(files, isEmpty);
    });

    test('a rich clipboard with no storable flavor and no text throws the '
        'unsupported hint (never silence)', () async {
      final reader = ClipboardReader([
        // HTML-only copy: advertised flavor that never delivers a payload,
        // no plain text — exactly the dead-end AC3 forbids hiding.
        _FakeItem(
          advertised: {Formats.htmlText},
          platformFormats: const ['public.html'],
        ),
      ]);

      await expectLater(
        readClipboardUploads(source: reader),
        throwsA(isA<FaClipboardUnsupportedException>()),
      );
    });

    test('unsupported rich flavors with plain text do NOT throw — the '
        'composer applies the text-paste rules', () async {
      final files = await readClipboardUploads(
        source: ClipboardReader([
          _FakeItem(
            advertised: {Formats.htmlText, Formats.plainText},
            values: {Formats.plainText: 'rich text copy'},
            platformFormats: const ['public.html'],
          ),
        ]),
      );
      expect(files, isEmpty);
    });
  });
}

/// A scripted clipboard item: the formats it advertises, the value-flavor
/// payloads (file URIs, plain text) and the file-flavor payloads it can
/// deliver. Only the members the walk actually touches behave; the rest
/// are inert defaults.
class _FakeItem extends ClipboardDataReader {
  _FakeItem({
    this.advertised = const {},
    this.values = const {},
    this.files = const {},
    this.platformFormats = const [],
  });

  final Set<DataFormat> advertised;
  final Map<ValueFormat<Object>, Object> values;
  final Map<FileFormat, (List<int>, String?)> files;
  @override
  final List<String> platformFormats;

  @override
  List<DataFormat> getFormats(List<DataFormat> allFormats) =>
      allFormats.where(advertised.contains).toList();

  @override
  Future<T?> readValue<T extends Object>(ValueFormat<T> format) async {
    final value = values[format];
    return value == null ? null : value as T;
  }

  @override
  ReadProgress? getValue<T extends Object>(
    ValueFormat<T> format,
    AsyncValueChanged<T?> onValue, {
    ValueChanged<Object>? onError,
  }) {
    final value = values[format];
    if (value == null) return null;
    scheduleMicrotask(() => onValue(value as T?));
    return _FakeProgress();
  }

  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) {
    final file = files[format];
    if (file == null) return null;
    scheduleMicrotask(
      () => onFile(_FakeFile(Uint8List.fromList(file.$1), file.$2)),
    );
    return _FakeProgress();
  }

  @override
  bool isSynthesized(DataFormat format) => false;

  @override
  bool isVirtual(DataFormat format) => false;

  @override
  Future<String?> getSuggestedName() async => null;

  @override
  Future<VirtualFileReceiver?> getVirtualFileReceiver({FileFormat? format}) =>
      Future.value(null);
}

class _FakeFile implements DataReaderFile {
  _FakeFile(this.bytes, this.fileName);

  final Uint8List bytes;

  @override
  final String? fileName;

  @override
  int? get fileSize => bytes.length;

  @override
  Stream<Uint8List> getStream() => Stream.value(bytes);

  @override
  void close() {}

  @override
  Future<Uint8List> readAll() async => bytes;
}

class _FakeProgress implements ReadProgress {
  final _fraction = ValueNotifier<double?>(1.0);
  final _cancellable = ValueNotifier<bool>(false);

  @override
  ValueListenable<double?> get fraction => _fraction;

  @override
  ValueListenable<bool> get cancellable => _cancellable;

  @override
  void cancel() {}
}
