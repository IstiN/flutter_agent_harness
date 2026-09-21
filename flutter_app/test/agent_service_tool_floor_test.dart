// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Tool-availability floor for mobile hosts (issue #692 B / AC1).
///
/// The iOS trajectory showed the model fighting a desktop-sized registry on
/// a WASI sandbox: desktop-only surfaces were either advertised in the
/// prompt or registered but un-runnable. The floor is CAPABILITY, not
/// desktopness — the app registers what the host can actually execute:
///
/// - surfaces needing host processes or a language-server transport (lsp,
///   MCP `mcp__*`, checkpoints/rewind, the sqlite FFI engine) are absent
///   from the app registry on every host, mobile included;
/// - sandbox-runnable tools STAY: `bash_job` runs Future-based jobs inside
///   the WASI sandbox (`WasiSandboxShell.backgroundJobsSupported`), and the
///   task family is LLM-backed — dropping them would shrink the surface
///   below what the sandbox can do.
///
/// The host-profile prompt (see `sandbox_registry.dart`) names the absent
/// surfaces; this suite pins that the claims match the registry reality.
library;

import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/sandbox/sandbox_registry.dart';
import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Builds the FULL production registry (the same AgentService.create the
  // app boots through) against an in-memory env — no platform channels are
  // exercised, only the composition.
  Future<AgentService> buildService() async {
    final service = await AgentService.create(
      config: AgentConfig(
        providerKind: 'openai-completions',
        modelId: 'test-model',
        baseUrl: 'https://example.test',
        apiKey: 'test-key',
      ),
      env: MemoryExecutionEnv(cwd: '/'),
    );
    return service;
  }

  group('app registry floor (issue #692 B)', () {
    test('desktop-only surfaces are absent from the app registry', () async {
      final service = await buildService();
      addTearDown(service.dispose);

      final names = service.registeredToolNamesForTest;
      // Process/transport-backed surfaces: the app never registers them —
      // the CLI (AgentCli) owns those registrations.
      expect(names, isNot(contains('lsp')), reason: 'LSP transport');
      expect(
        names.any((name) => name.startsWith('mcp__')),
        isFalse,
        reason: 'MCP server tools',
      );
      expect(names, isNot(contains('checkpoint')), reason: 'checkpoints');
      expect(names, isNot(contains('rewind')), reason: 'rewind');

      // The floor is capability, not desktopness: these RUN inside the
      // sandbox (Future-based jobs, LLM-backed children) and stay.
      expect(names, contains('bash_job'));
      expect(names, contains('task'));
      expect(names, contains('agent_message'));
    });

    test('the mobile host profile claims match the registry reality', () async {
      final service = await buildService();
      addTearDown(service.dispose);

      final names = service.registeredToolNamesForTest;
      final profile = formatSandboxHostProfile(SandboxPlatform.ios);
      // The profile names the desktop-only surfaces as NOT registered —
      // each claim is re-checked against the live registry so the prompt
      // can never drift ahead of the code.
      expect(profile, contains('LSP'));
      expect(names, isNot(contains('lsp')));
      expect(profile, contains('MCP'));
      expect(names.any((name) => name.startsWith('mcp__')), isFalse);
      expect(profile, contains('checkpoints'));
      expect(names, isNot(contains('checkpoint')));
      // ...and the classes it PROMISES are present.
      expect(profile, contains('file tools'));
      for (final promised in ['read', 'write', 'edit', 'ls', 'bash']) {
        expect(names, contains(promised), reason: 'profile promises $promised');
      }
    });
  });
}
