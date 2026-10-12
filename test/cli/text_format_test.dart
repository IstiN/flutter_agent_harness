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
      // Entries render as k<N>="<v>" — ~9 chars each over 30 entries, far
      // past the cap: the join must truncate to exactly 100 chars + '...'.
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
      // Rendered as k=" + 96 v's + " — 'k=' (2) + 2 quote chars + 96
      // values = exactly 100 chars, so the cap must not touch it.
      final value = 'v' * 96;
      expect(formatArgs({key: value}), 'k=${'v' * 96}');
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

    test('matches jsonEncode for serializable input (lossless)', () {
      final value = {'list': [1, 2, 3], 'nested': {'b': true}};
      expect(safeJsonEncode(value), jsonEncode(value));
    });
  });
}
