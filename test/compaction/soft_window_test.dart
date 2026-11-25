// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2411 — the soft-window regime: when the fixed request overhead plus
/// the never-dropped newest user turn already reaches the compaction
/// trigger, no trim can ever land a request under the window. The owner's
/// rule for that regime: the window is a soft target — skip relief, send
/// as is, warn once.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The incident's fixed overhead: 65,561 chars → 26,225 tokens at 2.5
/// chars/token (12,105 prompt + 34 schemas).
const _overheadChars = 65561;
const _window = 20000;
final _settings = CompactionSettings.forWindow(_window); // reserve 5000

const _question = 'hello what do you know about dmtools?';

List<Message> _turn() => [
  UserMessage.text('from network: You are a member of DAP channel'),
  UserMessage.text(_question),
];

void main() {
  group('windowBelowFixedOverhead (pure)', () {
    test('the overhead alone reaching the trigger is the regime', () {
      expect(
        windowBelowFixedOverhead(
          overheadTokens: 26225,
          window: _window,
          reserveTokens: _settings.reserveTokens,
        ),
        isTrue,
      );
    });

    test('the band below the window but above the trigger counts too', () {
      // 32k window / 8k reserve: a 25k overhead leaves no room the
      // trigger would ever accept, although requests under 32k exist.
      expect(
        windowBelowFixedOverhead(
          overheadTokens: 25000,
          window: 32768,
          reserveTokens: 8192,
        ),
        isTrue,
      );
      expect(
        windowBelowFixedOverhead(
          overheadTokens: 24000,
          window: 32768,
          reserveTokens: 8192,
        ),
        isFalse,
      );
    });

    test('the newest user turn is part of the floor that cannot shrink', () {
      // 14,995 sits 5 tokens under the trigger; the 12-token question
      // the valve must keep pushes the floor over it.
      expect(
        windowBelowFixedOverhead(
          overheadTokens: 14995,
          window: _window,
          reserveTokens: _settings.reserveTokens,
        ),
        isFalse,
      );
      expect(
        windowBelowFixedOverhead(
          overheadTokens: 14995,
          window: _window,
          reserveTokens: _settings.reserveTokens,
          newestUserTurnTokens: 12,
        ),
        isTrue,
      );
    });

    test(
      'an unlimited window is never in the regime; negative inputs clamp',
      () {
        expect(
          windowBelowFixedOverhead(
            overheadTokens: 1 << 30,
            window: 0,
            reserveTokens: 0,
          ),
          isFalse,
        );
        expect(
          windowBelowFixedOverhead(
            overheadTokens: 10,
            window: 100,
            reserveTokens: -50,
          ),
          isFalse,
        );
      },
    );
  });

  group('softWindowRegime (over a live transcript)', () {
    final prompt = 'p' * _overheadChars;

    test('the incident session: 20k window, ~26k overhead → the regime', () {
      expect(
        softWindowRegime(
          messages: _turn(),
          systemPrompt: prompt,
          tools: const [],
          window: _window,
          reserveTokens: _settings.reserveTokens,
        ),
        isTrue,
      );
    });

    test('a healthy 200k window with the same overhead is not', () {
      expect(
        softWindowRegime(
          messages: _turn(),
          systemPrompt: prompt,
          tools: const [],
          window: 200000,
          reserveTokens: CompactionSettings.forWindow(200000).reserveTokens,
        ),
        isFalse,
      );
    });

    test('a calibrated denser provider enters the regime the heuristic '
        'misses', () {
      // 34k prompt chars → 13,600 tokens (+ the 23-token turn): under the
      // 15k trigger on the heuristic; a 1.25x calibration puts it over.
      final small = 'p' * 34000;
      bool regime(OverheadCalibration calibration) => softWindowRegime(
        messages: _turn(),
        systemPrompt: small,
        tools: const [],
        window: _window,
        reserveTokens: _settings.reserveTokens,
        calibration: calibration,
      );
      expect(regime(OverheadCalibration.uncalibrated), isFalse);
      expect(regime(const OverheadCalibration(1.25)), isTrue);
    });

    test('the tool schemas count: a prompt-less request with 34 schemas', () {
      // 34 × (name + 1,200 description chars + 18 schema chars) ≈ 41.6k
      // chars → ~16.7k tokens at 2.5 chars/token: over the 15k trigger.
      final tools = [
        for (var i = 0; i < 34; i++)
          Tool(
            name: 'tool$i',
            description: 'd' * 1200,
            parameters: const {'type': 'object'},
          ),
      ];
      expect(
        softWindowRegime(
          messages: _turn(),
          systemPrompt: null,
          tools: tools,
          window: _window,
          reserveTokens: _settings.reserveTokens,
        ),
        isTrue,
      );
    });
  });
  group('SoftWindowNotice (once per session)', () {
    test('the same session is warned exactly once, whatever the overhead '
        'or the turn', () {
      final notice = SoftWindowNotice();
      expect(notice.shouldWarn('sid-a'), isTrue, reason: 'first sighting');
      expect(notice.shouldWarn('sid-a'), isFalse, reason: 'same session');
      expect(notice.shouldWarn('sid-a'), isFalse, reason: 'every later turn');
    });

    test('a new session (resume, /new) re-arms the warning', () {
      final notice = SoftWindowNotice();
      expect(notice.shouldWarn('sid-a'), isTrue);
      expect(notice.shouldWarn('sid-b'), isTrue, reason: 'a different session');
      expect(notice.shouldWarn('sid-b'), isFalse);
    });

    test('a session without an id yet warns on every sighting until the id '
        'is known (never silently swallows the warning)', () {
      final notice = SoftWindowNotice();
      expect(notice.shouldWarn(null), isTrue);
      expect(notice.shouldWarn(null), isTrue);
      expect(notice.shouldWarn('sid-a'), isTrue);
      expect(notice.shouldWarn('sid-a'), isFalse);
    });
  });
}
