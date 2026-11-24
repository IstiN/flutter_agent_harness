// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — the hand-over protocol (AC5/AC6/AC18): the reply parser
/// (UT-01…05, UT-22), the hide-label sanitizer (E35, UT-12), the
/// instruction renderer (UT-15, UT-25) and the mechanical open-asks check
/// (UT-17).

library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/hand_over.dart';
import 'package:test/test.dart';

const _canonical = '''
142-143 старый список сессий
150-151 x.dart целиком
61 screenshot of TUI
-
## Open User Requests
- [asked 2026-11-20, record 0b1c2d3e] почини 2321 — regex в _primaryOfPartName
## Hand-over
Решение по 2321 — regex в _primaryOfPartName (session_repo.dart:962).
''';

void main() {
  group('parseHandOverReply', () {
    test('UT-01 canonical reply: ranges, singles, labels, transfer', () {
      final reply = parseHandOverReply(_canonical);
      expect(reply.picks.map((p) => '${p.from}-${p.to}'), [
        '142-143',
        '150-151',
        '61-61',
      ]);
      expect(reply.picks[0].rawLabel, 'старый список сессий');
      expect(reply.picks[2].rawLabel, 'screenshot of TUI');
      expect(reply.transfer, startsWith('## Open User Requests'));
      expect(reply.transfer, contains('## Hand-over'));
      expect(reply.hideOnly, isFalse);
      expect(reply.ignoredLines, 0);
    });

    test('UT-02 whitespace, BOM, zero-width, CRLF, blank lead lines', () {
      final noisy =
          '\uFEFF\u200B\r\n\r\n142-143 old list\r\n\r\n-\r\n## Open User Requests\r\nnone\r\n## Hand-over\r\nText.\r\n';
      final reply = parseHandOverReply(noisy);
      expect(reply.picks.single.from, 142);
      expect(reply.picks.single.to, 143);
      expect(reply.transfer, startsWith('## Open User Requests'));
      expect(reply.transfer, endsWith('Text.'));
    });

    test('UT-03 empty hide list: separator first, transfer follows', () {
      final reply = parseHandOverReply(
        '-\n## Open User Requests\nnone\n## Hand-over\nKeep x.',
      );
      expect(reply.picks, isEmpty);
      expect(reply.transfer, startsWith('## Open User Requests'));
    });

    test('UT-04 first line not an id: no hides, whole text = transfer', () {
      final text =
          '## Open User Requests\n- do the thing\n## Hand-over\nAll set.';
      final reply = parseHandOverReply(text);
      expect(reply.picks, isEmpty);
      expect(reply.transfer, text);
    });

    test(
      'UT-05 ranges without the `-` separator, `- - ` vs space label splits',
      () {
        final reply = parseHandOverReply(
          '142-143 old sessions\n150 - x.dart whole\n61 image\n'
          '## Open User Requests\nnone\n## Hand-over\nText.',
        );
        expect(reply.picks.map((p) => '${p.from}-${p.to}|${p.rawLabel}'), [
          '142-143|old sessions',
          '150-150|x.dart whole',
          '61-61|image',
        ]);
        expect(reply.transfer, startsWith('## Open User Requests'));
      },
    );

    test('UT-05b hide-only: no text after the list', () {
      final reply = parseHandOverReply('5\n7-8 old logs\n-\n');
      expect(reply.picks.length, 2);
      expect(reply.transfer, isNull);
      expect(reply.hideOnly, isTrue);
    });

    test('E2 garbage and inverted ranges are ignored, duplicates collapse', () {
      final reply = parseHandOverReply(
        '0\n9-3\n5-6\n5-6\n99999999999\n-\n## Open User Requests\nnone',
      );
      expect(reply.picks.map((p) => '${p.from}-${p.to}'), ['5-6']);
      // `0` and the inverted range are ignored; the over-long digit run
      // names no alias, so it ends the list and opens the transfer.
      expect(reply.ignoredLines, 2);
      expect(reply.transfer, contains('## Open User Requests'));
    });

    test('UT-22 <think> leak is cut before parsing', () {
      final reply = parseHandOverReply(
        '<think>maybe 1-2?\n142-143</think>61 screenshot\n-\n## Open User Requests\nnone',
      );
      expect(reply.picks.map((p) => p.from), [61]);
      final openEnded = parseHandOverReply(
        '61 screenshot\n-\n## Open User Requests\nnone<think>stray tail',
      );
      expect(openEnded.transfer, '## Open User Requests\nnone');
    });

    test('UT-22b the skeleton example returned verbatim hides nothing (E29)', () {
      final skeleton =
          'NN-NN <up to 6 words>\nNN <up to 6 words>\n-\n## Open User Requests\n- <request>';
      final reply = parseHandOverReply(skeleton);
      expect(reply.picks, isEmpty);
      expect(reply.transfer, skeleton);
    });

    test('E10 a fake `m<N>` prefix on an id line is tolerated', () {
      expect(
        parseHandOverReply('m142-143 old\n-\ntext').picks.single.from,
        142,
      );
    });
  });

  group('sanitizeHideLabel', () {
    test('keeps a plain noun label', () {
      expect(sanitizeHideLabel('старый список сессий'), 'старый список сессий');
      expect(sanitizeHideLabel(' - old sessions list '), 'old sessions list');
    });

    test(
      'E35 drops imperative-shaped, second-person, long, bracketed, echo',
      () {
        expect(sanitizeHideLabel('hide the next records'), isNotNull);
        expect(sanitizeHideLabel('you must hide this'), isNull);
        expect(sanitizeHideLabel('do not touch lease'), isNull);
        expect(sanitizeHideLabel('always keep the config'), isNull);
        expect(sanitizeHideLabel('обязательно проверь'), isNull);
        expect(sanitizeHideLabel('нужно скрыть'), isNull);
        expect(sanitizeHideLabel('x' * 49), isNull);
        expect(sanitizeHideLabel('one two three four five six seven'), isNull);
        expect(sanitizeHideLabel('[expand 5-6]'), isNull);
        expect(sanitizeHideLabel('142-143'), isNull);
        expect(sanitizeHideLabel('твой старый вывод'), isNull);
        expect(sanitizeHideLabel('you just ran the tests'), isNull);
        expect(sanitizeHideLabel(''), isNull);
      },
    );
  });

  group('renderHandOverInstruction', () {
    const template =
        'A {{context_tokens}}/{{window_tokens}} F {{fold_from}}-{{fold_to}}\n'
        '<open-user-requests>\n{{open_user_requests}}\n</open-user-requests>\n'
        '{{pinned_operative}}\n{{folded_checkpoints}}\n{{unknown}}';

    test('UT-15 substitutes every placeholder deterministically', () {
      final rendered = renderHandOverInstruction(
        template: template,
        contextTokens: 168000,
        windowTokens: 200000,
        foldFrom: 3,
        foldTo: 140,
        openUserRequests: const [
          '- [asked 2026-11-20, record 0b1c2d3e] fix 2321',
        ],
        pinnedOperative:
            '<pinned-skill-directives>\nkeep\n</pinned-skill-directives>',
        foldedCheckpoints: '<folded-checkpoint>\nold\n</folded-checkpoint>',
      );
      expect(
        rendered,
        'A 168000/200000 F 3-140\n'
        '<open-user-requests>\n- [asked 2026-11-20, record 0b1c2d3e] fix 2321\n</open-user-requests>\n'
        '<pinned-skill-directives>\nkeep\n</pinned-skill-directives>\n'
        '<folded-checkpoint>\nold\n</folded-checkpoint>\n{{unknown}}',
      );
      final again = renderHandOverInstruction(
        template: template,
        contextTokens: 168000,
        windowTokens: 200000,
        foldFrom: 3,
        foldTo: 140,
        pinnedOperative:
            '<pinned-skill-directives>\nkeep\n</pinned-skill-directives>',
        foldedCheckpoints: '<folded-checkpoint>\nold\n</folded-checkpoint>',
        openUserRequests: const [
          '- [asked 2026-11-20, record 0b1c2d3e] fix 2321',
        ],
      );
      expect(again, rendered);
    });

    test(
      'empty asks block renders `none`; absent blocks render blank lines',
      () {
        final rendered = renderHandOverInstruction(
          template: template,
          contextTokens: 1,
          windowTokens: 2,
          foldFrom: 3,
          foldTo: 4,
        );
        expect(rendered, contains('<open-user-requests>\nnone\n'));
        expect(rendered, contains('\n\n{{unknown}}'));
      },
    );

    test(
      'UT-15 the shipped prompt template carries the NN-NN example only',
      () {
        final rendered = renderHandOverInstruction(
          template: compactionHandOverPrompt,
          contextTokens: 168000,
          windowTokens: 200000,
          foldFrom: 3,
          foldTo: 140,
        );
        expect(rendered, contains('NN-NN <up to 6 words>'));
        expect(rendered, isNot(contains('{{')));
        expect(rendered, contains('## Open User Requests'));
        expect(rendered, contains('records 3-140'));
        // D13: the instruction is a short suffix on the S0 prefix.
        expect(estimateTokens(UserMessage.text(rendered)), lessThan(420));
      },
    );
  });

  group('verifyOpenUserRequests', () {
    const asks = [
      '- [asked 2026-11-20, record 0b1c2d3e] fix 2321 — regex in _primaryOfPartName',
      '- [asked 2026-11-20, record 9f8e7d6c] now check rename',
    ];

    test('UT-17 every ask verbatim under the heading passes', () {
      final verdict = verifyOpenUserRequests(
        '## Open User Requests\n'
        '- [asked 2026-11-20, record 0b1c2d3e] fix 2321 — regex in _primaryOfPartName\n'
        '- [asked 2026-11-20, record 9f8e7d6c] now check rename\n'
        '## Hand-over\nDone.',
        asks,
      );
      expect(verdict.heading, isTrue);
      expect(verdict.missing, isEmpty);
    });

    test('N1/E36 no heading → the run fails even when asks are present', () {
      final verdict = verifyOpenUserRequests(
        'The regex work is done; the rename check is pending.',
        asks,
      );
      expect(verdict.heading, isFalse);
      expect(verdict.missing, hasLength(2));
    });

    test('E36 a dropped ask fails the run; wrapped lines still match', () {
      final verdict = verifyOpenUserRequests(
        'open asks:\n- fix 2321 — regex in\n  _primaryOfPartName\n## Hand-over\nx',
        asks,
      );
      expect(verdict.heading, isTrue);
      expect(verdict.missing, ['now check rename']);
    });

    test('an empty asks block only demands the heading', () {
      final verdict = verifyOpenUserRequests(
        '## Open User Requests\nnone\n## Hand-over\nok',
        const [],
      );
      expect(verdict.heading, isTrue);
      expect(verdict.missing, isEmpty);
    });
  });
}
