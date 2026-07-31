// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration coverage for the keys flows: a key saved in the settings
/// Keys section lands in the platform-appropriate store (a faked Keychain
/// channel on iOS) and is injected into the agent's shell environment on
/// the next connect; a `request_secret` grant persists and is immediately
/// available to bash.
library;

import 'dart:io';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'integration_fakes.dart';

/// An env with a working in-memory shell (bash env-var expansion rides
/// [ShellExecOptions.env], which [SecretsExecutionEnv] injects into).
MemoryExecutionEnv _shelledEnv() {
  final shell = MemoryShell();
  final env = MemoryExecutionEnv(cwd: '/', shell: shell);
  shell.attach(env);
  return env;
}

AgentConfig get _config => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'test-model',
  baseUrl: 'https://example.com/v1',
  apiKey: '',
);

void main() {
  // Keeps AgentService.create's `.env` read off the real filesystem.
  Directory emptyCwd() => Directory('/nonexistent-fah-test-dir');

  group('Keys section → platform store → agent env', () {
    const channel = MethodChannel('fah/keychain');
    final backend = <String, String>{};

    setUp(() {
      backend.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'isAvailable':
                return true;
              case 'readAll':
                return Map<String, String>.of(backend);
              case 'set':
                backend[call.arguments['name'] as String] =
                    call.arguments['value'] as String;
                return true;
              case 'delete':
                backend.remove(call.arguments['name'] as String);
                return true;
            }
            return null;
          });
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('a key saved in the Keys section lands in the Keychain and '
        'is injected into the agent env on connect', (tester) async {
      await IOOverrides.runZoned(() async {
        final env = _shelledEnv();
        final store = await SessionKeysStore.load(
          env,
          keychain: const KeychainStore(),
        );
        expect(store.usesKeychain, isTrue);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildFahTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(child: KeysSection(store: store)),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Add key dialog: name + value, then Save.
        await tester.tap(find.text('Add key'));
        await tester.pumpAndSettle();
        final dialogFields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        expect(dialogFields, findsNWidgets(2));
        await tester.enterText(dialogFields.first, 'MY_TOKEN');
        await tester.enterText(dialogFields.last, 'secret-token-value');
        // Let the button enable (it rebuilds off the text controllers).
        await tester.pump();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        // The value went to the Keychain backend, never the plaintext file.
        expect(backend['MY_TOKEN'], 'secret-token-value');
        expect(
          (await env.readTextFile(
            '${env.cwd}/${SessionKeysStore.fileName}',
          )).valueOrNull,
          isNull,
        );
        // Values are never displayed.
        expect(find.text('secret-token-value'), findsNothing);
        // The Keychain part is done; the platform override must be unset
        // before the test body ends (the invariant check runs before
        // tearDown). The group tearDown still clears it on failure paths.
        debugDefaultTargetPlatformOverride = null;

        // The next connect injects the saved key into the agent's shell
        // environment. (runAsync: create() seeds bundled skills through
        // rootBundle — real IO that never completes in the fake zone.)
        final service = (await tester.runAsync(
          () => AgentService.create(
            config: _config,
            env: env,
            sessionKeys: store,
            streamFunction: scriptedTurns([(model) => textTurn(model, 'ok')]),
          ),
        ))!;
        addTearDown(service.dispose);
        final result = (await tester.runAsync(
          () => service.secretsEnvForTest!
              .exec('echo \$MY_TOKEN')
              .then((r) => r.valueOrNull!),
        ))!;
        expect(result.stdout.trim(), 'secret-token-value');
      }, getCurrentDirectory: emptyCwd);
    });
  });

  group('request_secret grant', () {
    testWidgets('a grant persists into the keys store and is live in the '
        'bash env without echoing the value', (tester) async {
      await IOOverrides.runZoned(() async {
        final env = _shelledEnv();
        final store = await SessionKeysStore.load(env);
        final service = (await tester.runAsync(
          () => AgentService.create(
            config: _config,
            env: env,
            sessionKeys: store,
            streamFunction: scriptedTurns([
              (model) => toolCallTurn(model, [
                ToolCall(
                  id: 'sec1',
                  name: 'request_secret',
                  arguments: const {
                    'name': 'GRANTED_KEY',
                    'reason': 'need it for the API',
                  },
                ),
              ]),
              (model) => textTurn(model, 'thanks, key saved'),
            ]),
          ),
        ))!;
        addTearDown(service.dispose);
        // The chat screen's bottom sheet answers for the user; the test
        // grants directly.
        service.secretRequestHandler = (name, reason) async =>
            RequestSecretResult(name: name, value: 'granted-secret-value');

        await tester.runAsync(() async {
          await service.initialize();
          await service.sendText('set up the key');
          await service.waitForIdle();
        });

        // Persisted into the keys store (and its file)…
        expect(store.valueOf('GRANTED_KEY'), 'granted-secret-value');
        expect(
          (await env.readTextFile(
            '${env.cwd}/${SessionKeysStore.fileName}',
          )).valueOrNull,
          contains('GRANTED_KEY'),
        );
        // … live in the shell environment for the next bash call …
        final result = (await tester.runAsync(
          () => service.secretsEnvForTest!
              .exec('echo \$GRANTED_KEY')
              .then((r) => r.valueOrNull!),
        ))!;
        expect(result.stdout.trim(), 'granted-secret-value');
        // … and the value never reached the transcript.
        final transcript = service.messages.map((m) => m.content).join('\n');
        expect(transcript, isNot(contains('granted-secret-value')));
        expect(
          service.messages.any(
            (m) => m.role == 'tool' && m.toolName == 'request_secret',
          ),
          isTrue,
        );
      }, getCurrentDirectory: emptyCwd);
    });
  });
}
