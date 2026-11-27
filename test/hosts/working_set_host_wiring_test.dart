// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C1 (AC1, AC11) — `working_set` on every host at birth: the tool
/// registers through `wireAgentCore` for ALL SEVEN built-in profiles (cli,
/// macos, ios, android, web, extension, outlook) with no host capability
/// and no availability id (outside the `tools:` scope stack — no load
/// mode or config can hide it), keeps the read tier, and survives
/// `toolSurfaceFor` for every built-in task agent type including the
/// read-only ones (children keep it). gh-210's `recite_goal` is gone
/// (AC4).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final _sevenHosts = <String, HostCapabilityProfile>{
  'cli': cliProfile,
  'macos': macosProfile,
  'ios': iosProfile,
  'android': androidProfile,
  'web': webProfile,
  'extension': extensionProfile,
  'outlook': outlookProfile,
};

void main() {
  // The MINIMAL service bundle: nothing optional is supplied, so the
  // run-narrowing turns every capability-gated cell off — the tool must
  // still be there (it needs no capability).
  final services = AgentCoreServices(baseEnv: MemoryExecutionEnv(cwd: '/w'));

  group('working_set registers on all seven hosts', () {
    for (final entry in _sevenHosts.entries) {
      test(entry.key, () {
        final wired = wireAgentCore(profile: entry.value, services: services);
        final tool = wired.tools.where((t) => t.name == 'working_set');
        expect(tool, hasLength(1), reason: '${entry.key} wires working_set');
        final workingSet = tool.single;
        expect(workingSet.tier, ApprovalTier.read);
        expect(
          wired.tools.where((t) => t.name == 'recite_goal'),
          isEmpty,
          reason: 'gh-210 retired, no alias (AC4)',
        );
        // Every built-in task agent type keeps it — read-only children too.
        final registry = TaskAgentRegistry();
        expect(registry.agents, isNotEmpty);
        for (final definition in registry.agents) {
          final surface = registry
              .toolSurfaceFor(definition, wired.tools)
              .map((t) => t.name);
          expect(
            surface,
            contains('working_set'),
            reason: '${definition.name} (readOnly: ${definition.readOnly})',
          );
          expect(surface, isNot(contains('task')));
        }
      });
    }
  });

  group('outside the tools: scope stack', () {
    test(
      'no availability id — no config key, load mode or gate can hide it',
      () {
        expect(toolAvailabilityIdOf('working_set'), isNull);
        expect(knownToolIds, isNot(contains('working_set')));
        expect(
          coreToolFamilies.values.any((n) => n.contains('working_set')),
          isFalse,
        );
        // gh-210's id retired with its tool.
        expect(knownToolIds, isNot(contains('recite_goal')));
        expect(coreToolFamilies.containsKey('recite_goal'), isFalse);
      },
    );
  });
}
