// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2411 — per-session overhead calibration: the provider's first valid
/// usage corrects the fixed-overhead heuristic for the UNANCHORED
/// estimates (fresh/resumed session, every turn after a compaction
/// zeroed the usage anchors), so the meter, the guard and the trigger
/// agree before the provider has answered again.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _reply(Usage usage, {String text = 'ok'}) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'anthropic-messages',
  provider: 'copilot',
  model: 'm1',
  usage: usage,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

/// The incident's Copilot anchors (records 23 / 26 of session 01a211b3).
Usage _cacheMiss(int input, int output) => Usage(
  input: input,
  output: output,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: input + output,
  cost: const UsageCost(),
);

Usage _cacheHit(int uncachedInput, int cacheRead, int output) => Usage(
  input: uncachedInput,
  output: output,
  cacheRead: cacheRead,
  cacheWrite: 0,
  totalTokens: uncachedInput + cacheRead + output,
  cost: const UsageCost(),
);

List<Tool> _tools(int count) => [
  for (var i = 0; i < count; i++)
    Tool(
      name: 'tool$i',
      description: 'd' * 80,
      parameters: const {'type': 'object'},
    ),
];

final _prompt = 'p' * 1000;

void main() {
  group('OverheadCalibration.fromUsage', () {
    test('the ratio is prompt tokens over the unanchored estimate', () {
      final calibration = OverheadCalibration.fromUsage(
        promptTokens: 24126,
        unanchoredRequestTokens: 16084,
      );
      expect(calibration.ratio, closeTo(1.5, 0.01));
      expect(calibration.measured, isTrue);
      expect(calibration.isCalibrated, isTrue);
      expect(calibration.apply(16084), 24126);
    });

    test('a provider counting LESS than the heuristic never lowers the '
        'estimate (clamped to 1.0, still a taken measurement)', () {
      final calibration = OverheadCalibration.fromUsage(
        promptTokens: 100,
        unanchoredRequestTokens: 400,
      );
      expect(calibration.ratio, OverheadCalibration.minRatio);
      expect(calibration.measured, isTrue);
      expect(calibration.isCalibrated, isFalse);
      expect(calibration.apply(400), 400);
    });

    test('a degenerate report clamps at 4x or stays uncalibrated', () {
      expect(
        OverheadCalibration.fromUsage(
          promptTokens: 100000,
          unanchoredRequestTokens: 100,
        ).ratio,
        OverheadCalibration.maxRatio,
      );
      expect(
        OverheadCalibration.fromUsage(
          promptTokens: 0,
          unanchoredRequestTokens: 100,
        ).measured,
        isFalse,
      );
      expect(
        OverheadCalibration.fromUsage(
          promptTokens: 100,
          unanchoredRequestTokens: 0,
        ).measured,
        isFalse,
      );
      expect(OverheadCalibration.uncalibrated.apply(0), 0);
    });
  });

  group('deriveOverheadCalibration', () {
    test('the FIRST valid usage anchors it — an aborted or error reply is '
        'not a usage', () {
      final messages = [
        UserMessage.text('a' * 400),
        _reply(
          _cacheMiss(500, 10),
          text: 'aborted reply',
        ).copyWith(stopReason: StopReason.aborted),
        _reply(_cacheMiss(300, 10)),
      ];
      final calibration = deriveOverheadCalibration(messages);
      // No prompt/tools: the request was the prefix alone (the user turn
      // plus the aborted reply the transcript kept).
      final prefix = estimateRequestTokens(messages.take(2).toList());
      expect(prefix, greaterThan(100));
      expect(calibration, isNotNull);
      expect(calibration!.ratio, closeTo(300 / prefix, 0.001));
    });

    test('the incident: 65,561 overhead chars priced by Copilot at 24,126 '
        '— the heuristic (26.2k) already reads higher, so the measurement '
        'clamps at 1.0 and the heuristic stands', () {
      final messages = [
        UserMessage.text('hello what do you know about dmtools?'),
        UserMessage.text('from network: You are a member of DAP channel'),
        _reply(_cacheMiss(24126, 175)),
      ];
      final unanchored = estimateRequestTokens(
        messages.take(2).toList(),
        systemPrompt: 'p' * 65561,
      );
      expect(unanchored, greaterThan(24126));
      final calibration = deriveOverheadCalibration(
        messages,
        systemPrompt: 'p' * 65561,
      )!;
      expect(calibration.measured, isTrue);
      expect(calibration.ratio, OverheadCalibration.minRatio);
    });

    test('a denser provider (40k tokens for the same overhead) calibrates '
        'the unanchored estimate UP to its number', () {
      final messages = [
        UserMessage.text('a' * 400),
        _reply(_cacheMiss(40000, 10)),
      ];
      final calibration = deriveOverheadCalibration(
        messages,
        systemPrompt: 'p' * 65561,
      )!;
      final calibrated = estimateRequestTokens(
        messages.take(1).toList(),
        systemPrompt: 'p' * 65561,
        calibration: calibration,
      );
      final unanchored = estimateRequestTokens(
        messages.take(1).toList(),
        systemPrompt: 'p' * 65561,
      );
      // 65,561 prompt chars → 26,225 tokens at 2.5 + the 100-token turn.
      expect(unanchored, 26325);
      expect(calibration.ratio, closeTo(40000 / 26325, 0.001));
      expect((calibrated - 40000).abs(), lessThanOrEqualTo(2));
    });

    test('a cache hit is priced as input + cacheRead (Copilot splits them) '
        '— the raw input field alone would under-count', () {
      // 226 uncached + 23,640 cached = 23,866 prompt tokens for a request
      // the heuristic estimates at ~20.1k: ratio ≈ 1.19. On the raw
      // `input` field (226) the ratio would clamp to 1.0.
      final messages = [
        UserMessage.text('a' * 400),
        _reply(_cacheHit(226, 23640, 147)),
      ];
      final unanchored = estimateRequestTokens(
        messages.take(1).toList(),
        systemPrompt: 'p' * 50000,
      );
      final calibration = deriveOverheadCalibration(
        messages,
        systemPrompt: 'p' * 50000,
      )!;
      expect(calibration.ratio, closeTo(23866 / unanchored, 0.001));
      expect(calibration.ratio, greaterThan(1.1));
    });

    test('a degenerate anchor (a tiny request, a huge bill) clamps at 4x', () {
      final messages = [
        UserMessage.text('a' * 400),
        _reply(_cacheHit(226, 23640, 147)),
      ];
      expect(
        deriveOverheadCalibration(messages)!.ratio,
        OverheadCalibration.maxRatio,
      );
    });

    test('no valid usage → null (nothing to calibrate from)', () {
      expect(
        deriveOverheadCalibration([
          UserMessage.text('a' * 400),
          _reply(Usage.zero),
        ]),
        isNull,
      );
      expect(deriveOverheadCalibration(const []), isNull);
    });

    test('the walk reads the OLDEST anchor, whatever follows it (a late '
        'anchor would dilute the overhead out of the ratio)', () {
      final first = [UserMessage.text('a' * 400), _reply(_cacheMiss(8000, 10))];
      final later = [...first, UserMessage.text('b' * 400000)];
      final ratio = deriveOverheadCalibration(first)!.ratio;
      expect(ratio, deriveOverheadCalibration(later)!.ratio);
    });
  });

  group('estimateRequestTokens with a calibration', () {
    final calibration = const OverheadCalibration(1.5);
    final tools = _tools(12);

    test('an UNANCHORED request scales transcript + overhead', () {
      final messages = [UserMessage.text('a' * 400)];
      final plain = estimateRequestTokens(
        messages,
        systemPrompt: _prompt,
        tools: tools,
      );
      expect(
        estimateRequestTokens(
          messages,
          systemPrompt: _prompt,
          tools: tools,
          calibration: calibration,
        ),
        (plain * 1.5).ceil(),
      );
    });

    test('an ANCHORED request is the provider number — never scaled', () {
      final messages = [
        UserMessage.text('a' * 400),
        _reply(_cacheMiss(1000, 10)),
      ];
      expect(
        estimateRequestTokens(
          messages,
          systemPrompt: _prompt,
          tools: tools,
          calibration: calibration,
        ),
        estimateRequestTokens(messages, systemPrompt: _prompt, tools: tools),
      );
    });

    test('the default is uncalibrated (every existing caller is '
        'byte-identical in shape)', () {
      final messages = [UserMessage.text('a' * 400)];
      expect(
        estimateRequestTokens(
          messages,
          systemPrompt: _prompt,
          tools: tools,
          calibration: OverheadCalibration.uncalibrated,
        ),
        estimateRequestTokens(messages, systemPrompt: _prompt, tools: tools),
      );
    });
  });
}
