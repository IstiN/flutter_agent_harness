// REG guard for the gh-1049 deflake (PR #1166, review r2): the memory
// round-trip leg's `Existing tags:` mock scenario must keep ONE scripted
// response per KBTagGeneratorAgent call — THREE per round trip:
//   1. memory_add → KBMemoryEnrichment (the add's tag enrichment)
//   2. memory_search → MemoryController.search() project scope (searchByText)
//   3. the same search() → user scope, because results.length < limit (the
//      KB holds fewer records than the limit-10 cap)
//      — lib/src/memory/memory_controller.dart `search()`.
// Dropping a response passes every screen and wire assert yet silently
// resurrects the 500-storm (script-exhausted HTTP 500 → 3 retries + 2×5s
// adapter sleeps + `[net] retrying` lines) that buries the tool rows and
// re-flakes the PTY wait. Hermetic source grep (no PTY, no network),
// deliberately in the DEFAULT suite so the pre-commit gate enforces it —
// same pattern as `pty_screen_wait_reg_test.dart`.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'memory leg scripts a response for every taggen call (gh-1049 pin)',
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

      final responses = RegExp(r'-\s+text:').allMatches(scenario).length;
      expect(
        responses,
        greaterThanOrEqualTo(3),
        reason:
            'the memory round trip makes THREE KBTagGeneratorAgent calls '
            '(add enrichment + project-scope search + user-scope search on '
            'the results < limit fallback — memory_controller.dart search()); '
            'a missing response exhausts the mock FIFO into the 500-retry '
            'storm that re-flakes the PTY wait (gh-1049, PR #1166 r0)',
      );
    },
  );
}
