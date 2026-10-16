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
      final args = {for (var i = 0; i < 30; i++) 'k$i': 'v$i'};
      final out = formatArgs(args);
      expect(out.length, 103); // 100 + '...'
      expect(out.endsWith('...'), isTrue);
      expect(out.startsWith('k0='), isTrue);
    });

    test('unquoted rendering of exactly 100 chars is not truncated', () {
      // The key renders RAW (never JSON-encoded); an int value encodes
      // without quotes: 98 + '=' + '1' = exactly 100, untouched.
      expect(formatArgs({'k' * 98: 1}), '${'k' * 98}=1');
    });

    test('quoted rendering counts the 2 JSON quote chars toward the cap', () {
      // k=" + 96 v's + " = exactly 100 — at the cap, not truncated. The
      // expected literal includes the quotes (they are part of the output).
      expect(formatArgs({'k': 'v' * 96}), 'k="${'v' * 96}"');
    });

    test('one char over the cap truncates mid-quote (closing quote cut)', () {
      // k=" + 97 v's + " = 101 > 100 → first 100 chars + '...': the
      // closing quote is amputated. Surprising, but it is what the
      // renderer does — coverage PR, pin actual behavior.
      expect(formatArgs({'k': 'v' * 97}), 'k="${'v' * 97}...');
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
      final value = {
        'list': [1, 2, 3],
        'nested': {'b': true},
      };
      expect(safeJsonEncode(value), jsonEncode(value));
    });
  });
}
