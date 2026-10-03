// REG guard for the memory round-trip leg's `Existing tags:` mock scenario
// (gh-1049 deflake PR #1166; gh-1171 turns the exact-count pin into a
// WILDCARD pin): the scenario must be `sticky: true` with at least ONE
// scripted response. The KBTagGeneratorAgent fires once per LLM-backed
// memory op — the add's enrichment, then one per search scope (project,
// then user: the KB holds fewer records than the limit-10 cap) — but the
// count is emergent from flutter_agent_memory internals
// (lib/src/memory/memory_controller.dart `search()`) and shifts with
// scheduling: gh-1171 saw a 4th call exhaust an exact-count script into
// the 500-storm (script-exhausted HTTP 500 → 3 retries + 2×5s adapter
// sleeps + `[net] retrying` lines) that buries the tool rows and re-flakes
// the PTY wait. The sticky wildcard answers every extra call with the
// scripted empty response forever; the parent-conversation scenario stays
// strict so a real loop regression still fails loudly. Hermetic source
// grep (no PTY, no network), deliberately in the DEFAULT suite so the
// pre-commit gate enforces it — same pattern as
// `pty_screen_wait_reg_test.dart`.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'memory leg scripts a sticky wildcard for every taggen call (gh-1171 pin)',
    () {
      final source = File(
        'test/integration/subagent_integration_test.dart',
      ).readAsStringSync();

      final memoryTestStart = source.indexOf(
        "test('memory_add and memory_search tools are available'",
      );
      expect(
        memoryTestStart,
        isNonNegative,
        reason: 'memory round-trip test not found — update this pin',
      );
      final memoryTest = source.substring(memoryTestStart);

      final scenarioStart = memoryTest.indexOf('- match: "Existing tags:"');
      expect(
        scenarioStart,
        isNonNegative,
        reason:
            'Existing tags: taggen scenario not found — update this pin',
      );
      final scenarioTail = memoryTest.substring(scenarioStart);
      final scriptEnd = scenarioTail.indexOf("''');");
      final scenario = scriptEnd < 0
          ? scenarioTail
          : scenarioTail.substring(0, scriptEnd);

      expect(
        scenario,
        contains('sticky: true'),
        reason:
            'the taggen scenario must stay a STICKY wildcard: the '
            'KBTagGeneratorAgent call count is schedule-dependent and an '
            'extra call against a dry exact-count script exhausts the mock '
            'FIFO into the 500-retry storm that re-flakes the PTY wait '
            '(gh-1171)',
      );
      final responses = RegExp(r'-\s+text:').allMatches(scenario).length;
      expect(
        responses,
        greaterThanOrEqualTo(1),
        reason:
            'a sticky scenario has nothing to re-serve without at least one '
            'scripted response (matched-but-dry still answers 500 — '
            'mock_llm_server.dart _nextEntry)',
      );
    },
  );
}
