// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/src/cli/text_format.dart';
import 'package:test/test.dart';

void main() {
  group('formatArgs', () {
    test('renders key=value pairs joined by commas', () {
      final out = formatArgs({'path': 'note.md', 'limit': '3'});
      expect(out, 'path="note.md", limit="3"');
    });

    test('string values are JSON-quoted, numbers are bare', () {
      expect(formatArgs({'n': 42}), 'n=42');
      expect(formatArgs({'s': 'x'}), 's="x"');
    });

    test('caps at 100 columns with an ellipsis', () {
      // 4 chars of "k=v," per entry × 30 entries > 100 — the join must be
      // truncated to exactly 100 chars + '...'.
      final args = {
        for (var i = 0; i < 30; i++) 'k$i': 'v$i',
      };
      final out = formatArgs(args);
      expect(out.length, 103); // 100 + '...'
      expect(out.endsWith('...'), isTrue);
      expect(out.startsWith('k0='), isTrue);
    });

    test('output of exactly 100 chars is not truncated', () {
      final key = 'k';
      final value = 'v' * 98; // 'k=' + 98 = 100 chars
      expect(formatArgs({key: value}), 'k=${'v' * 98}');
    });

    test('empty args render as an empty string', () {
      expect(formatArgs(const {}), '');
    });
  });

  group('safeJsonEncode', () {
    test('encodes plain values as JSON', () {
      expect(safeJsonEncode({'a': 1}), '{"a":1}');
      expect(safeJsonEncode('x'), '"x"');
      expect(safeJsonEncode(null), 'null');
    });

    test('a cyclic structure degrades to the placeholder, never throws', () {
      final cyclic = <String, dynamic>{'name': 'root'};
      cyclic['self'] = cyclic;
      expect(safeJsonEncode(cyclic), '[unserializable]');
    });

    test('an unserializable object degrades to the placeholder', () {
      expect(safeJsonEncode(Object()), '[unserializable]');
    });

    test('matches jsonEncode for serializable input (wrapper is lossless)',
        () {
      final value = {'list': [1, 2, 3], 'nested': {'b': true}};
      expect(safeJsonEncode(value), jsonEncode(value));
    });
  });
}
