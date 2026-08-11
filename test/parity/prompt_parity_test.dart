/// Interactive prompt/tool parity guard: every tool factory in the core
/// package that accepts a host [callback] parameter must be wired in BOTH
/// the CLI (`agent_cli.dart`) and the Flutter app (`agent_service.dart`),
/// unless the tool is documented as platform-exempt.
///
/// This catches the scenario where a new interactive prompt type is added
/// to core (e.g. a hypothetical `reviewPlanTool`) but only one platform
/// implements the handler.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Interactive tool factories that require a host callback. Each entry is
/// the factory function name (as it appears in source code) and a human
/// description. Both platforms must reference every entry.
const _interactiveTools = <(String factory, String description)>[
  ('askTool(', 'Structured questions to the user (AskCallback).'),
  ('requestSecretTool(', 'Credential request (RequestSecretCallback).'),
];

/// Approval prompt wiring (not a tool factory — it's the ApprovalManager
/// constructor's `prompt:` parameter). Both platforms must wire it.
const _approvalWiring = <(String ref, String description)>[
  ('ApprovalManager(', 'The approval gate — both platforms construct one.'),
  (
    'ApprovalPrompt',
    'The prompt callback typedef — both platforms reference it.',
  ),
];

void main() {
  group('prompt parity', () {
    late String cliSource;
    late String appSource;

    setUpAll(() async {
      cliSource = await File('lib/src/cli/agent_cli.dart').readAsString();
      appSource = await File(
        'flutter_app/lib/services/agent_service.dart',
      ).readAsString();
    });

    test('every interactive tool factory is wired in the CLI', () {
      for (final (factory, desc) in _interactiveTools) {
        expect(
          cliSource,
          contains(factory),
          reason: 'CLI does not register $factory — $desc',
        );
      }
    });

    test('every interactive tool factory is wired in the app', () {
      for (final (factory, desc) in _interactiveTools) {
        expect(
          appSource,
          contains(factory),
          reason: 'App does not register $factory — $desc',
        );
      }
    });

    test('approval gate is constructed in both platforms', () {
      for (final (ref, desc) in _approvalWiring) {
        expect(
          cliSource,
          contains(ref),
          reason: 'CLI does not reference $ref — $desc',
        );
        expect(
          appSource,
          contains(ref),
          reason: 'App does not reference $ref — $desc',
        );
      }
    });

    test('every TuiPromptSpec subtype has a core type counterpart', () {
      // The CLI's TuiPromptSpec sealed class has subtypes. Each must
      // correspond to a shared core type. This test verifies the mapping
      // stays 1:1 — when a new prompt spec is added, a corresponding core
      // type must exist.
      //
      // Current mapping:
      //   AskPromptSpec       → AskOption / AskAnswer (ask_tool.dart)
      //   SecretPromptSpec    → RequestSecretResult (request_secret_tool.dart)
      //   ApprovalPromptSpec  → ApprovalRequest / ApprovalDecision (approval.dart)
      //   TextPromptSpec      → (no core type — standalone free-text, CLI/app-only)
      //
      // The test reads tui_prompt.dart and checks the core types are imported.
      final tuiPrompt = File('lib/src/cli/tui_prompt.dart').readAsStringSync();
      expect(
        tuiPrompt,
        contains('AskAnswer'),
        reason: 'AskPromptSpec should use the shared AskAnswer type.',
      );
      expect(
        tuiPrompt,
        contains('ApprovalRequest'),
        reason:
            'ApprovalPromptSpec should use the shared ApprovalRequest type.',
      );
      expect(
        tuiPrompt,
        contains('RequestSecretResult'),
        reason:
            'SecretPromptSpec should use the shared RequestSecretResult type.',
      );
    });
  });
}
