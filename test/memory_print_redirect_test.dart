// gh-1510: the nightly `subagent_integration_test` went red because the
// screen buffer showed `memory round-tripcomplete` — the separating space
// was never painted. Root cause: `flutter_agent_memory` logs via bare
// `print()` (// ignore: avoid_print) on the CLI's main isolate; in TUI mode
// stdout IS the terminal, so the raw bytes interleave with the CellRenderer
// frame protocol, physically clobber cells, and the cell diff then skips
// repainting "unchanged" cells against the desynced grid.
//
// Fix: MemoryController runs every package-facing op inside a zone whose
// print delegates to the host-provided sink (the CLI wires the diagnostic
// log). This test pins both halves: the lines REACH the sink, and nothing
// reaches print()/stdout.

@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_memory/flutter_agent_memory.dart';
import 'package:test/test.dart';

/// Any provider works: the package prints the tag-generation prompt BEFORE
/// the LLM call, and a throwing chat just degrades (gh-1393 never-throw).
class _ThrowingProvider extends LlmProvider {
  @override
  final String defaultModel = 'probe-model';

  @override
  Future<String> chat(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) => throw Exception('probe: LLM unavailable');

  @override
  Future<String> chatMessages(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) => throw Exception('probe: LLM unavailable');
}

void main() {
  group('MemoryController print redirect (gh-1510)', () {
    test('package debug prints land in printSink, never on stdout', () async {
      final stdoutLines = <String>[];
      final sinkLines = <String>[];
      // The outer zone records everything that would reach print() — i.e.
      // the TUI terminal in production. Without the redirect the KB* lines
      // appear here and the test fails.
      await runZoned(
        () async {
          final controller = MemoryController(
            env: MemoryExecutionEnv(),
            llmProvider: _ThrowingProvider(),
            printSink: sinkLines.add,
          );
          await controller.add(text: 'durable keyword fact');
          await controller.search('keyword');
          await controller.list();
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => stdoutLines.add(line),
        ),
      );

      expect(
        sinkLines,
        isNotEmpty,
        reason: 'the package prints on the tag-generation path — the '
            'redirect must have something to catch',
      );
      expect(
        sinkLines.any((l) => l.contains('KBTagGeneratorAgent')),
        isTrue,
        reason: 'tag-generation prints must reach the sink',
      );
      expect(
        stdoutLines.where((l) => l.contains('KBTagGeneratorAgent')),
        isEmpty,
        reason: 'a package print reaching stdout writes raw bytes into the '
            'TUI frame stream (gh-1510 screen corruption)',
      );
      expect(
        stdoutLines.where((l) => l.contains('KBSearchEngine')),
        isEmpty,
        reason: 'search prints must be intercepted too',
      );
    });

    test('without printSink the historical print behavior is preserved', () async {
      final stdoutLines = <String>[];
      await runZoned(
        () async {
          final controller = MemoryController(
            env: MemoryExecutionEnv(),
            llmProvider: _ThrowingProvider(),
          );
          await controller.add(text: 'durable keyword fact');
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => stdoutLines.add(line),
        ),
      );
      // Null sink = pass-through (embedders/headless keep the package's
      // debug output; the TUI host always wires the diagnostic log).
      expect(
        stdoutLines.any((l) => l.contains('KBTagGeneratorAgent')),
        isTrue,
      );
    });
  });
}
