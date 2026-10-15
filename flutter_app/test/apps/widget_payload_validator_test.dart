// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Unit tests for the shared widget payload validator (gh-1616 UT-*): the
// one ruleset the unpacked loader (and #1614-style storage reads) run over
// an in-memory `apps/<id>/` payload BEFORE anything is written to the env.
//
// The manifest schema strings are byte-identical with the fa_widgets
// catalog engine (the same `WidgetManifest` parser the catalog CI runs —
// issue #1045's one-ruleset invariant), so a payload rejected here is
// rejected there with the same words.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/widget_payload_validator.dart';
import 'package:flutter_test/flutter_test.dart';

WidgetPayloadValidation validate(
  Map<String, Object?> manifest, {
  Map<String, String>? extra,
  Map<String, Uint8List>? files,
}) {
  return const WidgetPayloadValidator().validate(
    files ??
        {
          'manifest.json': utf8.encode(jsonEncode(manifest)),
          'widget.js': utf8.encode('jsr.render({type:"text",data:"hi"});'),
          ...?extra?.map((k, v) => MapEntry(k, utf8.encode(v))),
        },
  );
}

void main() {
  group('WidgetPayloadValidator — valid payloads', () {
    test('minimal manifest.json + widget.js passes', () {
      final result = validate({
        'id': 'fa-agents',
        'name': 'FA Agents',
        'version': '1.2.3',
      });
      expect(result.isValid, isTrue, reason: '${result.errors}');
      expect(result.manifest?['id'], 'fa-agents');
      expect(result.id, 'fa-agents');
      expect(result.network, isFalse);
      expect(result.allowedCommands, isEmpty);
    });

    test('multi-file payload (helper modules) passes with 2+ files', () {
      final result = validate(
        {'id': 'my-widget', 'name': 'My Widget', 'version': '0.1.0'},
        extra: {
          'lib/helpers.js': "import './deep/more.js';",
          'lib/deep/more.js': 'export const x = 1;',
        },
      );
      expect(result.isValid, isTrue, reason: '${result.errors}');
      expect(result.files.keys, containsAll(['lib/helpers.js', 'widget.js']));
    });

    test('every id matching [a-z0-9][a-z0-9-]{1,31} passes', () {
      for (final id in ['ab', 'a1', 'fa-agents', 'a${'b' * 31}']) {
        final result = validate({'id': id, 'name': 'x', 'version': '1.0.0'});
        expect(
          result.isValid,
          isTrue,
          reason: 'id "$id" should be valid: ${result.errors}',
        );
      }
    });

    test('declared tile entry present in the payload passes', () {
      final result = validate(
        {
          'id': 'tiled',
          'name': 'Tiled',
          'version': '1.0.0',
          'widget': {'entry': 'widget_tile.js', 'refreshSeconds': 900},
        },
        extra: {'widget_tile.js': 'tile.refresh();'},
      );
      expect(result.isValid, isTrue, reason: '${result.errors}');
    });

    test('web-picker shape (single root folder) is normalized away', () {
      final result = const WidgetPayloadValidator().validate({
        'fa-agents/manifest.json': utf8.encode(
          jsonEncode({'id': 'fa-agents', 'name': 'FA Agents'}),
        ),
        'fa-agents/widget.js': utf8.encode('jsr.render(null);'),
      });
      expect(result.isValid, isTrue, reason: '${result.errors}');
      expect(result.files.keys.toSet(), {'manifest.json', 'widget.js'});
    });
  });

  group('WidgetPayloadValidator — named errors (gh-1616 AC2)', () {
    test('missing manifest.json names the file and the looked paths', () {
      final result = const WidgetPayloadValidator().validate({
        'widget.js': utf8.encode('jsr.render(null);'),
      });
      expect(result.isValid, isFalse);
      expect(result.errors.map((e) => e.code), contains('manifest_missing'));
      expect(
        result.errors.map((e) => e.message).join('\n'),
        contains('manifest.json'),
      );
    });

    test('malformed JSON is a named manifest_malformed error', () {
      final result = const WidgetPayloadValidator().validate({
        'manifest.json': utf8.encode('{not json'),
        'widget.js': utf8.encode('x'),
      });
      expect(result.errors.map((e) => e.code), contains('manifest_malformed'));
      expect(
        result.errors.map((e) => e.message).join('\n'),
        contains('manifest.json is not valid JSON'),
      );
    });

    test('a non-object manifest is named, never thrown raw', () {
      final result = const WidgetPayloadValidator().validate({
        'manifest.json': utf8.encode('[1,2]'),
        'widget.js': utf8.encode('x'),
      });
      expect(result.errors.map((e) => e.code), contains('manifest_invalid'));
      expect(
        result.errors.map((e) => e.message).join('\n'),
        contains('manifest must be a JSON object'),
      );
    });

    test('schema breaks carry the catalog engine strings verbatim', () {
      final result = const WidgetPayloadValidator().validate({
        'manifest.json': utf8.encode(jsonEncode({'version': '1.0.0'})),
        'widget.js': utf8.encode('x'),
      });
      expect(result.errors.map((e) => e.code), contains('manifest_invalid'));
      expect(
        result.errors.map((e) => e.message).join('\n'),
        contains("'id' must be a non-empty string"),
      );
    });

    test('bad ids are rejected with the id pattern named', () {
      for (final id in [
        'Big',
        'has_underscore',
        '-starts-dash',
        'a',
        'a${'b' * 32}', // 33 chars — one over the cap
        'has.dot',
        '../escape',
      ]) {
        final result = validate({'id': id, 'name': 'x', 'version': '1.0.0'});
        expect(
          result.errors.map((e) => e.code),
          contains('id_invalid'),
          reason: 'id "$id" must be rejected',
        );
        expect(
          result.errors.map((e) => e.message).join('\n'),
          contains('[a-z0-9][a-z0-9-]{1,31}'),
        );
      }
    });

    test('a whitespace-padded id is rejected with the trimmed form named', () {
      // gh-1616 review round 2: the id rule runs on `id.trim()`, so a
      // padded-but-otherwise-valid id would PASS validation and then be
      // stored byte-padded — where `JsAppInfo.fromManifest` parses the
      // padded model id back, the trimmed install record misses it and
      // Remove targets a folder that does not exist. The pad itself is
      // the named error; the fix belongs at the validator, not at the
      // loader's consumption point.
      final result = validate({
        'id': ' fa-agents ',
        'name': 'x',
        'version': '1.0.0',
      });
      expect(result.isValid, isFalse);
      final idErrors = result.errors
          .where((e) => e.code == 'id_invalid')
          .toList();
      expect(idErrors, hasLength(1), reason: '${result.errors}');
      expect(idErrors.single.message, contains('whitespace'));
      expect(
        idErrors.single.message,
        contains('fa-agents'),
        reason: 'the trimmed form the manifest must carry is named',
      );
    });

    test('a padded id that ALSO breaks the pattern names both problems', () {
      final result = validate({'id': ' BAD ID ', 'name': 'x'});
      final messages = result.errors
          .where((e) => e.code == 'id_invalid')
          .map((e) => e.message);
      expect(messages, hasLength(2), reason: '${result.errors}');
      expect(
        messages.where((m) => m.contains('whitespace')),
        hasLength(1),
      );
      expect(
        messages.where((m) => m.contains('[a-z0-9][a-z0-9-]{1,31}')),
        hasLength(1),
      );
    });

    test('traversal ids cannot survive: apps/… escapes are impossible', () {
      final result = validate({'id': '../../../etc', 'name': 'x'});
      expect(result.errors.map((e) => e.code), contains('id_invalid'));
    });

    test('missing widget.js is a named entry_missing error', () {
      final result = const WidgetPayloadValidator().validate({
        'manifest.json': utf8.encode(
          jsonEncode({'id': 'no-entry', 'name': 'X'}),
        ),
      });
      expect(result.errors.map((e) => e.code), contains('entry_missing'));
      expect(
        result.errors.map((e) => e.message).join('\n'),
        contains('widget.js'),
      );
    });

    test('an empty widget.js is a named entry_empty error', () {
      final result = const WidgetPayloadValidator().validate({
        'manifest.json': utf8.encode(
          jsonEncode({'id': 'empty-entry', 'name': 'X'}),
        ),
        'widget.js': utf8.encode(''),
      });
      expect(result.errors.map((e) => e.code), contains('entry_empty'));
    });

    test('a declared tile entry that is missing is a named error', () {
      final result = validate({
        'id': 'tiled',
        'name': 'Tiled',
        'version': '1.0.0',
        'widget': {'entry': 'widget_tile.js'},
      });
      expect(result.errors.map((e) => e.code), contains('tile_entry_missing'));
      expect(
        result.errors.map((e) => e.message).join('\n'),
        contains('widget_tile.js'),
      );
    });

    test('unsafe paths (../ or absolute) are rejected before any write', () {
      final result = const WidgetPayloadValidator().validate({
        'manifest.json': utf8.encode(
          jsonEncode({'id': 'escapee', 'name': 'X'}),
        ),
        'widget.js': utf8.encode('x'),
        '../evil.js': utf8.encode('pwn'),
        '/abs.js': utf8.encode('pwn'),
      });
      expect(result.errors.map((e) => e.code), contains('path_unsafe'));
    });

    test('E4: a huge widget.js hits the size cap with a clear message', () {
      final result = const WidgetPayloadValidator().validate({
        'manifest.json': utf8.encode(jsonEncode({'id': 'huge', 'name': 'X'})),
        'widget.js': Uint8List(WidgetPayloadValidator.maxFileBytes + 1),
      });
      expect(result.errors.map((e) => e.code), contains('file_too_large'));
      expect(result.errors.map((e) => e.message).join('\n'), contains('KB'));
    });

    test('E4: many mid-size files hit the package cap', () {
      final chunk = Uint8List(1024 * 1024);
      final files = <String, Uint8List>{
        'manifest.json': utf8.encode(jsonEncode({'id': 'fat', 'name': 'X'})),
        'widget.js': Uint8List(1024),
      };
      for (
        var i = 0;
        i < WidgetPayloadValidator.maxPackageBytes ~/ (1024 * 1024);
        i++
      ) {
        files['blob$i.bin'] = chunk;
      }
      final result = const WidgetPayloadValidator().validate(files);
      expect(result.errors.map((e) => e.code), contains('package_too_large'));
    });
  });

  group('WidgetPayloadValidator — warnings do not block the load', () {
    test('a declared icon that is missing is a warning only', () {
      final result = validate({
        'id': 'iconless',
        'name': 'X',
        'version': '1.0.0',
        'icon': 'icon.svg',
      });
      expect(result.isValid, isTrue);
      expect(result.warnings.map((w) => w.code), contains('icon_missing'));
    });

    test('a non-semver version warns (the loader is not the catalog CI)', () {
      final result = validate({'id': 'loose', 'name': 'X', 'version': '1.0'});
      expect(result.isValid, isTrue, reason: '${result.errors}');
      expect(
        result.warnings.map((w) => w.code),
        contains('version_not_semver'),
      );
    });

    test('unknown manifest keys warn forward-compat, like the catalog', () {
      final result = validate({
        'id': 'fwd',
        'name': 'X',
        'version': '1.0.0',
        'futureThing': true,
      });
      expect(result.isValid, isTrue, reason: '${result.errors}');
      expect(
        result.warnings.map((w) => w.code),
        contains('unknown_manifest_key'),
      );
    });
  });

  group('WidgetPayloadValidator — declared capability surface', () {
    test('network + allowedCommands are surfaced for the load confirm', () {
      final result = validate({
        'id': 'netty',
        'name': 'Netty',
        'version': '1.0.0',
        'network': true,
        'allowedCommands': ['git status'],
      });
      expect(result.network, isTrue);
      expect(result.allowedCommands, ['git status']);
    });
  });
}
