import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('SecretRedactor', () {
    test('masks exact matches with ***', () {
      final redactor = SecretRedactor()..register('TOKEN', 'abc123def456');
      expect(
        redactor.redact('the token is abc123def456 ok'),
        'the token is *** ok',
      );
    });

    test('masks multiple occurrences and multiple secrets', () {
      final redactor = SecretRedactor()
        ..register('A', 'secret-one')
        ..register('B', 'secret-two');
      expect(
        redactor.redact('secret-one and secret-two and secret-one'),
        '*** and *** and ***',
      );
    });

    test('ignores values shorter than 8 chars', () {
      final redactor = SecretRedactor()
        ..register('SHORT', '1234567')
        ..register('EXACT', '12345678');
      expect(redactor.names, ['EXACT']);
      expect(
        redactor.redact('1234567 stays, 12345678 goes'),
        '1234567 stays, *** goes',
      );
    });

    test('empty redactor and empty text pass through unchanged', () {
      final redactor = SecretRedactor();
      expect(redactor.isEmpty, isTrue);
      expect(redactor.names, isEmpty);
      expect(redactor.redact('anything'), 'anything');
      expect(
        SecretRedactor.fromSecrets(const {'X': 'xxxxxxxxxx'}).redact(''),
        '',
      );
    });

    test('fromSecrets registers a whole map; names never expose values', () {
      final redactor = SecretRedactor.fromSecrets(const {
        'B_KEY': 'value-b-123',
        'A_KEY': 'value-a-456',
      });
      expect(redactor.names, ['A_KEY', 'B_KEY']);
      expect(redactor.redact('value-a-456/value-b-123'), '***/***');
    });
  });

  group('InMemorySecretsStore', () {
    test('readAll returns initial values and reflects set/remove', () async {
      final store = InMemorySecretsStore(const {'A': '1'});
      expect(await store.readAll(), {'A': '1'});
      store.set('B', '2');
      expect(await store.readAll(), {'A': '1', 'B': '2'});
      store.remove('A');
      expect(await store.readAll(), {'B': '2'});
    });

    test('readAll result is unmodifiable', () async {
      final store = InMemorySecretsStore(const {'A': '1'});
      final all = await store.readAll();
      expect(() => all['B'] = '2', throwsUnsupportedError);
    });
  });

  group('redactionHooks', () {
    const secret = 'sk-live-1234567890';
    final redactor = SecretRedactor.fromSecrets(const {'KEY': secret});

    AfterToolCallContext contextFor(String text) => AfterToolCallContext(
      assistantMessage: AssistantMessage(
        content: const [],
        api: 'test',
        provider: 'test',
        model: 'test',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      ),
      toolCall: ToolCall(id: 'tc-1', name: 'bash', arguments: const {}),
      result: ToolExecutionResult.text(text),
      isError: false,
      context: Context(messages: const []),
    );

    test('afterToolCall masks secret values in the tool result', () async {
      final hooks = redactionHooks(redactor);
      final result = await hooks.afterToolCall(
        contextFor('key: $secret and again $secret'),
        null,
      );
      expect(result, isNotNull);
      final text = result!.content!.whereType<TextContent>().single.text;
      expect(text, 'key: *** and again ***');
    });

    test('afterToolCall returns null when nothing matched', () async {
      final hooks = redactionHooks(redactor);
      final result = await hooks.afterToolCall(
        contextFor('plain output'),
        null,
      );
      expect(result, isNull);
    });

    test(
      'transformContext masks user, assistant, and tool-result text',
      () async {
        final hooks = redactionHooks(redactor);
        final messages = <Message>[
          UserMessage.text('use $secret please'),
          ToolResultMessage(
            toolCallId: 'tc-1',
            toolName: 'bash',
            content: [TextContent(text: 'echoed $secret')],
            isError: false,
            timestamp: DateTime.now(),
          ),
          AssistantMessage(
            content: [
              ThinkingContent(thinking: 'thinking about $secret'),
              TextContent(text: 'the key is $secret'),
            ],
            api: 'test',
            provider: 'test',
            model: 'test',
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          ),
        ];
        final transformed = await hooks.transformContext(messages, null);
        expect((transformed[0] as UserMessage).content, 'use *** please');
        final toolText =
            ((transformed[1] as ToolResultMessage).content.single
                    as TextContent)
                .text;
        expect(toolText, 'echoed ***');
        final assistant = transformed[2] as AssistantMessage;
        expect(
          (assistant.content[0] as ThinkingContent).thinking,
          'thinking about ***',
        );
        expect((assistant.content[1] as TextContent).text, 'the key is ***');
      },
    );

    test('transformContext masks UserMessage content blocks', () async {
      final hooks = redactionHooks(redactor);
      final message = UserMessage(
        content: [TextContent(text: 'block with $secret')],
        timestamp: DateTime.now(),
      );
      final transformed = await hooks.transformContext([message], null);
      final block =
          ((transformed.single as UserMessage).content as List<ContentBlock>)
                  .single
              as TextContent;
      expect(block.text, 'block with ***');
    });
  });

  group('attachSecretRedactor', () {
    const secret = 'sk-live-1234567890';

    Agent agentWith(AfterToolCallHook? after, TransformContextHook? transform) {
      return Agent(
        streamFunction: (model, context, {cancelToken}) =>
            AssistantMessageEventStream()..end(),
        toolRegistry: ToolRegistry(const []),
        afterToolCall: after,
        transformContext: transform,
      );
    }

    AfterToolCallContext contextFor(String text) => AfterToolCallContext(
      assistantMessage: AssistantMessage(
        content: const [],
        api: 'test',
        provider: 'test',
        model: 'test',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      ),
      toolCall: ToolCall(id: 'tc-1', name: 'bash', arguments: const {}),
      result: ToolExecutionResult.text(text),
      isError: false,
      context: Context(messages: const []),
    );

    test('composes with a pre-existing afterToolCall hook', () async {
      final agent = agentWith((context, cancelToken) {
        return AfterToolCallResult(
          content: [TextContent(text: 'wrapped $secret')],
        );
      }, null);
      attachSecretRedactor(
        agent,
        SecretRedactor.fromSecrets(const {'K': secret}),
      );

      final result = await agent.afterToolCall!(
        contextFor('raw $secret'),
        null,
      );
      final text = result!.content!.whereType<TextContent>().single.text;
      // Existing hook ran (replaced content) and redaction masked its output.
      expect(text, 'wrapped ***');
    });

    test('composes with a pre-existing transformContext hook', () async {
      final agent = agentWith(null, (messages, cancelToken) {
        return [...messages, UserMessage.text('appended $secret')];
      });
      attachSecretRedactor(
        agent,
        SecretRedactor.fromSecrets(const {'K': secret}),
      );

      final transformed = await agent.transformContext!([
        UserMessage.text('original'),
      ], null);
      expect(transformed, hasLength(2));
      expect((transformed[1] as UserMessage).content, 'appended ***');
    });
  });

  group('SecretsExecutionEnv', () {
    test('exec merges secrets into ShellExecOptions.env', () async {
      final shell = _RecordingShell();
      final env = SecretsExecutionEnv(
        MemoryExecutionEnv(cwd: '/', shell: shell),
        const {'SECRET': 's3cr3t-value'},
      );
      await env.exec(
        'echo x',
        options: ShellExecOptions(
          env: const {'OTHER': '1'},
          timeout: const Duration(seconds: 5),
        ),
      );
      final options = shell.lastOptions!;
      expect(options.env, {'SECRET': 's3cr3t-value', 'OTHER': '1'});
      expect(options.timeout, const Duration(seconds: 5));
    });

    test('per-call env wins over injected secrets', () async {
      final shell = _RecordingShell();
      final env = SecretsExecutionEnv(
        MemoryExecutionEnv(cwd: '/', shell: shell),
        const {'SECRET': 's3cr3t-value'},
      );
      await env.exec(
        'x',
        options: ShellExecOptions(env: const {'SECRET': 'override'}),
      );
      expect(shell.lastOptions!.env, {'SECRET': 'override'});
    });

    test('exec with no options still injects secrets', () async {
      final shell = _RecordingShell();
      final env = SecretsExecutionEnv(
        MemoryExecutionEnv(cwd: '/', shell: shell),
        const {'SECRET': 's3cr3t-value'},
      );
      await env.exec('x');
      expect(shell.lastOptions!.env, {'SECRET': 's3cr3t-value'});
    });

    test('empty secrets pass options through untouched', () async {
      final shell = _RecordingShell();
      final env = SecretsExecutionEnv(
        MemoryExecutionEnv(cwd: '/', shell: shell),
        const {},
      );
      await env.exec('x');
      expect(shell.lastOptions, isNull);
    });

    test('filesystem operations delegate to the wrapped env', () async {
      final env = SecretsExecutionEnv(MemoryExecutionEnv(cwd: '/'), const {
        'SECRET': 's3cr3t-value',
      });
      expect(env.cwd, '/');
      expect(env.delegate, isA<MemoryExecutionEnv>());
      await env.writeFile('/a.txt', 'hi');
      expect((await env.readTextFile('/a.txt')).valueOrNull, 'hi');
      expect((await env.exists('/a.txt')).valueOrNull, isTrue);
      expect((await env.fileInfo('/a.txt')).valueOrNull!.name, 'a.txt');
      expect(
        (await env.listDir('/')).valueOrNull!.map((f) => f.name),
        contains('a.txt'),
      );
      expect((await env.readTextLines('/a.txt')).valueOrNull, ['hi']);
      expect((await env.absolutePath('a.txt')).valueOrNull, '/a.txt');
      expect((await env.joinPath(['a', 'b'])).valueOrNull, '/a/b');
      await env.appendFile('/a.txt', '!');
      expect((await env.readBinaryFile('/a.txt')).valueOrNull, isNotEmpty);
      await env.createDir('/d');
      expect((await env.exists('/d')).valueOrNull, isTrue);
      await env.remove('/a.txt');
      expect((await env.exists('/a.txt')).valueOrNull, isFalse);
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
