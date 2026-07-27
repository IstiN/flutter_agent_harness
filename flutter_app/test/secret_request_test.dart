import 'package:flutter/material.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/widgets/secret_request_sheet.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _requestName = 'GITHUB_TOKEN';
const _requestReason = 'I need it to push the branch to origin.';
const _grantedValue = 'ghp_test-secret-value';

/// Pumps a button that opens the secret request sheet and completes [result].
Future<void> _pumpOpener(
  WidgetTester tester, {
  required void Function(RequestSecretResult?) onResult,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              onResult(
                await showSecretRequestSheet(
                  context,
                  _requestName,
                  _requestReason,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

FilledButton _saveButton(WidgetTester tester) {
  return tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
}

void main() {
  group('SecretRequestSheet', () {
    testWidgets('renders the reason and a prefilled editable name', (
      tester,
    ) async {
      await _pumpOpener(tester, onResult: (_) {});
      await _openSheet(tester);

      expect(find.text('Fa needs a key'), findsOneWidget);
      expect(find.text(_requestReason), findsOneWidget);
      expect(find.text('Key name'), findsOneWidget);
      expect(find.text('Key value'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        _requestName,
      );
      // No value yet: Save is disabled.
      expect(_saveButton(tester).onPressed, isNull);
    });

    testWidgets('Save returns the granted name and value', (tester) async {
      RequestSecretResult? result;
      await _pumpOpener(tester, onResult: (r) => result = r);
      await _openSheet(tester);
      await tester.enterText(find.byType(TextField).at(1), _grantedValue);
      await tester.pumpAndSettle();
      expect(_saveButton(tester).onPressed, isNotNull);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.name, _requestName);
      expect(result!.value, _grantedValue);
    });

    testWidgets('an edited name is uppercased and validated inline', (
      tester,
    ) async {
      RequestSecretResult? result;
      await _pumpOpener(tester, onResult: (r) => result = r);
      await _openSheet(tester);
      await tester.enterText(find.byType(TextField).first, 'bad name');
      await tester.enterText(find.byType(TextField).at(1), _grantedValue);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(
        find.text('Use UPPER_SNAKE: A–Z, 0–9, _, starting with a letter'),
        findsOneWidget,
      );
      // Fixing the name clears the error and saves.
      await tester.enterText(find.byType(TextField).first, 'gh_token');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.name, 'GH_TOKEN');
    });

    testWidgets('Not now resolves with null', (tester) async {
      var completed = false;
      RequestSecretResult? result;
      await _pumpOpener(
        tester,
        onResult: (r) {
          completed = true;
          result = r;
        },
      );
      await _openSheet(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(result, isNull);
    });
  });

  group('AgentService request_secret wiring', () {
    Future<({AgentService service, AgentTool tool})> createService({
      required _RecordingShell shell,
      SessionKeysStore? sessionKeys,
    }) async {
      final service = await AgentService.create(
        config: AgentConfig(
          providerKind: 'openai-completions',
          modelId: 'test-model',
          baseUrl: 'https://example.test',
          apiKey: 'test-key',
        ),
        env: MemoryExecutionEnv(cwd: '/', shell: shell),
        sessionKeys: sessionKeys,
      );
      final tool = service.toolsForTest.whereType<AgentTool>().singleWhere(
        (tool) => tool.name == 'request_secret',
      );
      return (service: service, tool: tool);
    }

    String textOf(ToolExecutionResult result) => result.content
        .whereType<TextContent>()
        .map((block) => block.text)
        .join();

    test(
      'a grant is persisted, injected into the shell env, and redacted',
      () async {
        final shell = _RecordingShell();
        final keys = SessionKeysStore.inMemory();
        final (:service, :tool) = await createService(
          shell: shell,
          sessionKeys: keys,
        );
        addTearDown(service.dispose);

        String? askedName;
        String? askedReason;
        service.secretRequestHandler = (name, reason) async {
          askedName = name;
          askedReason = reason;
          return RequestSecretResult(name: name, value: _grantedValue);
        };
        final result = await tool.execute(
          const {'name': _requestName, 'reason': _requestReason},
          null,
          null,
        );
        expect(
          textOf(result),
          'Secret $_requestName saved and available as \$$_requestName.',
        );
        expect(askedName, _requestName);
        expect(askedReason, _requestReason);

        // Persisted into the Keys store.
        expect(keys.valueOf(_requestName), _grantedValue);

        // Live in the shell environment of later exec calls.
        await service.env.exec('echo \$$_requestName');
        expect(shell.lastOptions!.env![_requestName], _grantedValue);

        // Registered with the redactor: the name is advertised, the value is
        // masked out of agent-visible text.
        final redactor = service.redactorForTest!;
        expect(redactor.names, contains(_requestName));
        expect(redactor.redact('token: $_grantedValue'), 'token: ***');
      },
    );

    test('a grant without a Keys store reports session-only', () async {
      final shell = _RecordingShell();
      final (:service, :tool) = await createService(shell: shell);
      addTearDown(service.dispose);
      service.secretRequestHandler = (name, reason) async =>
          RequestSecretResult(name: name, value: _grantedValue);
      final result = await tool.execute(
        const {'name': _requestName, 'reason': _requestReason},
        null,
        null,
      );
      expect(textOf(result), contains('this session only'));
      // Still injected into the live shell env for this session.
      await service.env.exec('echo \$$_requestName');
      expect(shell.lastOptions!.env![_requestName], _grantedValue);
    });

    test('a decline saves nothing and reports the decline', () async {
      final shell = _RecordingShell();
      final keys = SessionKeysStore.inMemory();
      final (:service, :tool) = await createService(
        shell: shell,
        sessionKeys: keys,
      );
      addTearDown(service.dispose);
      service.secretRequestHandler = (name, reason) async => null;
      final result = await tool.execute(
        const {'name': _requestName, 'reason': _requestReason},
        null,
        null,
      );
      expect(textOf(result), 'The user declined to provide $_requestName.');
      expect(keys.has(_requestName), isFalse);
      expect(service.redactorForTest!.names, isNot(contains(_requestName)));
    });

    test('without a handler the request resolves as declined', () async {
      final shell = _RecordingShell();
      final (:service, :tool) = await createService(shell: shell);
      addTearDown(service.dispose);
      final result = await tool.execute(
        const {'name': _requestName, 'reason': _requestReason},
        null,
        null,
      );
      expect(textOf(result), 'The user declined to provide $_requestName.');
    });
  });
}

final class _RecordingShell implements Shell {
  ShellExecOptions? lastOptions;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    lastOptions = options;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}
