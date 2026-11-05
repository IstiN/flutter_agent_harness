// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2059 AC2 — the extension SW host's slash dispatch: `/compact` runs a
/// compaction instead of riding the wire as a literal user message (the
/// incident's relay-224 record), and an unknown `/word` is answered locally
/// like the CLI's REPL ("unknown command: $command") instead of being sent
/// to the model. Path-shaped single tokens (`/a/b`) and a bare `/` stay
/// ordinary text — CLI parity.
library;

import '../src/slash_commands.dart';
import 'package:test/test.dart';

void main() {
  group('dispatchExtUserInput', () {
    test('plain text stays a message, trimmed', () {
      final d = dispatchExtUserInput('  fill the form  ');
      expect(d, isA<ExtUserMessage>());
      expect((d as ExtUserMessage).text, 'fill the form');
    });

    test('/compact (bare and with arguments) is the compact command', () {
      expect(dispatchExtUserInput('/compact'), isA<ExtCompactCommand>());
      final withArgs = dispatchExtUserInput('/compact focus on the DOM');
      expect(withArgs, isA<ExtCompactCommand>());
    });

    test('/compact survives surrounding whitespace and newlines', () {
      expect(dispatchExtUserInput('  /compact\n'), isA<ExtCompactCommand>());
    });

    test('an unknown single-token command is answered locally, not sent', () {
      final d = dispatchExtUserInput('/compcat');
      expect(d, isA<ExtUnknownCommand>());
      expect((d as ExtUnknownCommand).command, '/compcat');
    });

    test('path-shaped tokens and a bare slash stay messages (CLI parity)', () {
      for (final text in ['/usr/local/bin', '/a/b', '/', '//']) {
        expect(dispatchExtUserInput(text), isA<ExtUserMessage>(), reason: text);
      }
    });

    test('empty and whitespace-only input stay messages', () {
      expect(dispatchExtUserInput(''), isA<ExtUserMessage>());
      expect(dispatchExtUserInput('   '), isA<ExtUserMessage>());
    });

    test('a compact mention mid-sentence is NOT a command', () {
      expect(dispatchExtUserInput('please /compact the page'), isA<ExtUserMessage>());
    });

    test('case matters: /Compact is an unknown command, not /compact', () {
      final d = dispatchExtUserInput('/Compact');
      expect(d, isA<ExtUnknownCommand>());
    });
  });
}
