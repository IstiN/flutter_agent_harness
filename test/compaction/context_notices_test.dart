// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C3 — the honest context notices: the post-hide text and its
/// numbers, the no-snapshot variant, the near-limit formula per window
/// size, re-arm, the forbidden-phrase list, the N counter over
/// hide records of every mechanism (`hidden_range`,
/// `compact_checkpoint`, the classic `compaction` boundary) and the
/// once-per-cycle latch (AC6, AC7, I6); the prompt includes never use a
/// forbidden phrase.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart';
import 'package:test/test.dart';

void main() {
  group('post-hide notice (AC6)', () {
    const pinned =
        'compacted: 303 records hidden; '
        'context now ≈53924/200000 (was ≈185555); '
        'your working set is pinned — continue';
    const bare =
        'compacted: 303 records hidden; '
        'context now ≈53924/200000 (was ≈185555); '
        'no working set yet — write one now with working_set(text), '
        'then continue';

    test('the pinned variant is the card text with the harness numbers', () {
      expect(
        postHideNoticeLine(
          hiddenRecords: 303,
          tokensNow: 53924,
          tokensBefore: 185555,
          window: 200000,
          hasWorkingSet: true,
        ),
        pinned,
      );
    });

    test('the no-snapshot variant names the fix (E2)', () {
      expect(
        postHideNoticeLine(
          hiddenRecords: 303,
          tokensNow: 53924,
          tokensBefore: 185555,
          window: 200000,
          hasWorkingSet: false,
        ),
        bare,
      );
    });

    test('rides the synthetic-user envelope', () {
      final notice = postHideContextNotice(
        hiddenRecords: 424,
        tokensNow: 35568,
        tokensBefore: 280065,
        window: 200000,
        hasWorkingSet: false,
      );
      expect(notice, startsWith('<system-notice>\n'));
      expect(notice, endsWith('\n</system-notice>'));
      expect(isSyntheticUserText(notice), isTrue);
      expect(
        isSyntheticUserText(userMessageText(UserMessage.text(notice).content)),
        isTrue,
        reason: 'a notice record is machine content for every classifier',
      );
    });

    test('an unknown window yields no notice (no honest number)', () {
      expect(
        postHideContextNotice(
          hiddenRecords: 3,
          tokensNow: 1,
          tokensBefore: 2,
          window: 0,
          hasWorkingSet: true,
        ),
        isEmpty,
      );
    });
  });

  group('near-limit notice (AC7)', () {
    test('the card wording with the real numbers at the threshold', () {
      expect(
        nearLimitNoticeLine(tokens: 170000, window: 200000),
        'context ≈85% (≈170000/200000): update your working set with '
        'decisions, red tests and next steps, then KEEP WORKING; '
        'compaction will fold older records',
      );
      // Where the trigger's runway dominates, the percent is the REAL one.
      expect(
        nearLimitNoticeLine(tokens: 22000, window: 32000),
        startsWith('context ≈69% (≈22000/32000): '),
      );
    });

    test('formula: 200k window → 170k (85 %)', () {
      expect(
        nearLimitThresholdTokens(
          window: 200000,
          settings: CompactionSettings.forWindow(200000),
        ),
        170000,
      );
    });

    test('formula: 32k window with an 8k reserve → 22k (the runway wins)', () {
      const settings = CompactionSettings(
        enabled: true,
        reserveTokens: 8000,
        keepRecentTokens: 2000,
      );
      final threshold = nearLimitThresholdTokens(
        window: 32000,
        settings: settings,
      );
      expect(threshold, 22000);
      // Always BELOW the hide trigger with the runway.
      expect(threshold, 32000 - 8000 - 2000);
    });

    test('formula: the runway is max(2,000, 5 % of the window)', () {
      expect(nearLimitRunwayTokens(200000), 10000);
      expect(nearLimitRunwayTokens(32000), 2000);
      expect(nearLimitRunwayTokens(0), 2000);
      // A 1M window: 85 % (850k) sits below trigger − 5 % (887.5k).
      expect(
        nearLimitThresholdTokens(
          window: 1000000,
          settings: CompactionSettings.forWindow(1000000),
        ),
        850000,
      );
    });

    test('an unknown window or disabled compaction never reaches it', () {
      const settings = CompactionSettings(
        enabled: true,
        reserveTokens: 8000,
        keepRecentTokens: 2000,
      );
      expect(
        nearLimitReached(tokens: 31000, window: 0, settings: settings),
        isFalse,
      );
      expect(
        nearLimitReached(
          tokens: 31000,
          window: 32000,
          settings: const CompactionSettings(
            enabled: false,
            reserveTokens: 8000,
            keepRecentTokens: 2000,
          ),
        ),
        isFalse,
      );
      expect(nearLimitNoticeLine(tokens: 5, window: 0), isEmpty);
    });

    test('reached exactly at the threshold, not below', () {
      final settings = CompactionSettings.forWindow(200000);
      expect(
        nearLimitReached(tokens: 169999, window: 200000, settings: settings),
        isFalse,
      );
      expect(
        nearLimitReached(tokens: 170000, window: 200000, settings: settings),
        isTrue,
      );
    });

    test('never at or over the hide trigger — the hide speaks there', () {
      final settings = CompactionSettings.forWindow(200000);
      final trigger = 200000 - settings.reserveTokens;
      expect(trigger, greaterThan(170000));
      expect(
        nearLimitReached(
          tokens: trigger - 1,
          window: 200000,
          settings: settings,
        ),
        isTrue,
      );
      expect(
        nearLimitReached(tokens: trigger, window: 200000, settings: settings),
        isFalse,
        reason: 'the hide runs next: its post-hide notice is the message',
      );
      expect(
        nearLimitReached(tokens: 199000, window: 200000, settings: settings),
        isFalse,
      );
    });

    test('every heuristic figure carries the ≈ (the one-basis rule)', () {
      // Owner directive: a heuristic number is marked as one everywhere
      // it is shown; only a provider-reported figure is exact.
      expect(estimateMark, '≈');
      final estimate = nearLimitNoticeLine(tokens: 170000, window: 200000);
      expect(estimate, startsWith('context ≈85% (≈170000/200000): '));
      final reported = nearLimitNoticeLine(
        tokens: 170000,
        window: 200000,
        estimated: false,
      );
      expect(reported, startsWith('context 85% (170000/200000): '));
      // …and the classifier knows both provenances.
      expect(isContextNoticeText(contextNoticeEnvelope(estimate)), isTrue);
      expect(isContextNoticeText(contextNoticeEnvelope(reported)), isTrue);
      expect(
        isContextNoticeText(
          contextNoticeEnvelope('context whatever a user might say'),
        ),
        isFalse,
      );
    });

    test('the post-hide line marks X and Y the same way', () {
      const exact =
          'compacted: 4 records hidden; context now 11842/12927 '
          '(was 23229); your working set is pinned — continue';
      const estimated =
          'compacted: 4 records hidden; context now '
          '≈11842/12927 (was ≈23229); your working set is pinned — continue';
      expect(
        postHideNoticeLine(
          hiddenRecords: 4,
          tokensNow: 11842,
          tokensBefore: 23229,
          window: 12927,
          hasWorkingSet: true,
        ),
        estimated,
      );
      expect(
        postHideNoticeLine(
          hiddenRecords: 4,
          tokensNow: 11842,
          tokensBefore: 23229,
          window: 12927,
          hasWorkingSet: true,
          estimated: false,
        ),
        exact,
      );
      expect(isContextNoticeText(contextNoticeEnvelope(estimated)), isTrue);
      expect(isContextNoticeText(contextNoticeEnvelope(exact)), isTrue);
    });

    test('rides the synthetic-user envelope', () {
      final notice = nearLimitContextNotice(tokens: 170000, window: 200000);
      expect(isSyntheticUserText(notice), isTrue);
      expect(notice, contains('KEEP WORKING'));
    });
  });

  group('isContextNoticeText — the precise notice classifier', () {
    test('both notice kinds inside the envelope are context notices', () {
      expect(
        isContextNoticeText(
          postHideContextNotice(
            hiddenRecords: 3,
            tokensNow: 120,
            tokensBefore: 400,
            window: 1000,
            hasWorkingSet: true,
          ),
        ),
        isTrue,
      );
      expect(
        isContextNoticeText(nearLimitContextNotice(tokens: 900, window: 1000)),
        isTrue,
      );
    });

    test('a bare line without the envelope is not a notice record', () {
      expect(
        isContextNoticeText(
          postHideNoticeLine(
            hiddenRecords: 3,
            tokensNow: 120,
            tokensBefore: 400,
            window: 1000,
            hasWorkingSet: true,
          ),
        ),
        isFalse,
      );
      expect(
        isContextNoticeText(nearLimitNoticeLine(tokens: 9, window: 10)),
        isFalse,
      );
    });

    test('every other `<system-notice>` record is NOT a context notice', () {
      // Compaction carriers, steering receipts and job notices ride the
      // same envelope — a classifier keyed on the notices must not
      // swallow them.
      expect(
        isContextNoticeText(contextNoticeEnvelope('job sh-1 done')),
        isFalse,
      );
      expect(
        isContextNoticeText(
          contextNoticeEnvelope('[legacy-ckpt·classic·not-expandable] …'),
        ),
        isFalse,
      );
      expect(isContextNoticeText('wrap up now'), isFalse);
      expect(isContextNoticeText(''), isFalse);
    });
  });

  group('forbidden phrases (I6)', () {
    test('the list is the card\'s four', () {
      expect(contextNoticeForbiddenPhrases, [
        'at the limit',
        'context limit',
        'out of context',
        'cannot continue',
      ]);
    });

    test('no notice text ever contains one', () {
      final texts = <String>[
        for (final has in [true, false])
          for (final window in [1, 32000, 200000, 1000000])
            for (final tokens in [0, 1, window ~/ 2, window, window * 3])
              postHideNoticeLine(
                hiddenRecords: 1371,
                tokensNow: tokens,
                tokensBefore: window * 3,
                window: window,
                hasWorkingSet: has,
              ),
        for (final window in [1, 32000, 200000, 1000000])
          for (final tokens in [0, window ~/ 2, window, window * 3])
            nearLimitNoticeLine(tokens: tokens, window: window),
      ];
      expect(texts, isNotEmpty);
      for (final text in texts) {
        expect(
          containsForbiddenContextPhrase(text),
          isFalse,
          reason: 'forbidden phrase in: $text',
        );
      }
      // The detector itself sees each phrase (case-insensitive).
      for (final phrase in contextNoticeForbiddenPhrases) {
        expect(
          containsForbiddenContextPhrase('You are ${phrase.toUpperCase()}'),
          isTrue,
        );
      }
      expect(
        containsForbiddenContextPhrase('context ≈85% (≈170000/200000)'),
        isFalse,
      );
    });
  });

  group('N — the records a hide pass hid', () {
    final h1 = HiddenRangeRecord(
      id: 'h1',
      parentId: null,
      timestamp: DateTime.utc(2026),
      recordIds: const ['a', 'b'],
    );
    final h2 = HiddenRangeRecord(
      id: 'h2',
      parentId: 'h1',
      timestamp: DateTime.utc(2026),
      recordIds: const ['c'],
    );

    test('counts the ids of the ranges appended after the snapshot', () {
      final known = hiddenRangeIdsIn([h1]);
      expect(known, {'h1'});
      expect(newlyHiddenRecordCount([h1], known), 0, reason: 'no new hide');
      expect(newlyHiddenRecordCount([h1, h2], known), 1);
      expect(
        newlyHiddenRecordCount([h1, h2], {}),
        3,
        reason: 'multi-pass total',
      );
    });

    test('a custom record (the working set) is invisible to the count', () {
      final custom = CustomRecord(
        id: 'w',
        parentId: null,
        timestamp: DateTime.utc(2026),
        customType: workingSetRecordType,
        data: const {'text': 'x'},
      );
      expect(newlyHiddenRecordCount([h1, custom], {}), 2);
    });

    test('a structured checkpoint is a hide too (its covered records)', () {
      // Issue #148 pass 2: the checkpoint's text replaces the records it
      // covers — the settle funnel hides this way, so the notice counts
      // it. A checkpoint swallowed by a later one is a carrier, not a
      // hidden transcript record; a record covered twice counts once.
      final ck1 = CompactCheckpointRecord(
        id: 'ck1',
        parentId: null,
        timestamp: DateTime.utc(2026),
        firstRecordId: 'm1',
        lastRecordId: 'm9',
        text: 'checkpoint',
        coversRecordIds: const ['m1', 'm2', 'm3'],
        flattenedRecordIds: const [],
      );
      final ck2 = CompactCheckpointRecord(
        id: 'ck2',
        parentId: 'ck1',
        timestamp: DateTime.utc(2026),
        firstRecordId: 'm1',
        lastRecordId: 'm12',
        text: 'checkpoint 2',
        coversRecordIds: const ['ck1', 'm3', 'm10'],
        flattenedRecordIds: const ['ck1'],
      );
      expect(hiddenRangeIdsIn([h1, ck1]), {'h1', 'ck1'});
      expect(newlyHiddenRecordCount([h1, ck1], {'h1'}), 3);
      expect(newlyHiddenRecordCount([h1, ck1, ck2], {'h1', 'ck1'}), 1);
      expect(newlyHiddenRecordCount([h1, ck1, ck2], {}), 6);
      expect(newlyHiddenRecordCount([ck2], {}), 3);
    });

    test('a legacy classic summary boundary is a hide too (positional)', () {
      // The classic engine: `compaction` record c1 keeps from m3 on, so
      // m1 + m2 are hidden; c2 keeps from m5 on, so m3 + m4 join. The
      // boundary's own id is the snapshot key, like every hide record.
      MessageRecord message(int i) => MessageRecord(
        id: 'm$i',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('m$i'),
      );
      CompactionRecord boundary(String id, String firstKept) =>
          CompactionRecord(
            id: id,
            parentId: null,
            timestamp: DateTime.utc(2026),
            summary: 'summary',
            firstKeptEntryId: firstKept,
            tokensBefore: 0,
          );
      final entries = [
        message(1),
        message(2),
        boundary('c1', 'm3'),
        message(3),
        message(4),
        boundary('c2', 'm5'),
        message(5),
      ];
      expect(isHideRecord(entries[2]), isTrue);
      expect(isHideRecord(entries[0]), isFalse);
      expect(hiddenRangeIdsIn([h1, ...entries]), {'h1', 'c1', 'c2'});
      expect(newlyHiddenRecordCount([h1, ...entries], {'h1', 'c1'}), 2);
      expect(newlyHiddenRecordCount([...entries], {'c1'}), 2);
      expect(newlyHiddenRecordCount(entries, {}), 4);
      expect(newlyHiddenRecordCount(entries, {'c1', 'c2'}), 0);
    });
  });

  group('the includes never contradict the notices (I6)', () {
    test('no "limit" phrase a notice is forbidden to use', () {
      for (final text in [workingSetPrompt, contextHygienePrompt]) {
        expect(
          containsForbiddenContextPhrase(text),
          isFalse,
          reason: text.substring(0, 40),
        );
      }
    });
  });

  group('ContextNoticeLatch', () {
    test('hands the notice out exactly once, re-arms on a hide', () {
      final latch = ContextNoticeLatch();
      expect(latch.armed, isTrue, reason: 'armed at session start');
      expect(latch.take(), isTrue);
      expect(latch.take(), isFalse, reason: 'once per cycle');
      expect(latch.armed, isFalse);
      latch.rearm();
      expect(latch.take(), isTrue);
    });

    test('one latch per session — instances are independent', () {
      final a = ContextNoticeLatch();
      final b = ContextNoticeLatch();
      expect(a.take(), isTrue);
      expect(b.take(), isTrue, reason: 'another session is another cycle');
    });
  });
}
