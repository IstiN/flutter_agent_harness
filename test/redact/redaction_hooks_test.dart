import 'package:flutter_agent_harness/src/agent/agent.dart';
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/redact/redaction_hooks.dart';
import 'package:flutter_agent_harness/src/redact/redaction_pipeline.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

const _ghp = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';

Never _neverStream(Model model, Context context, {CancelToken? cancelToken}) =>
    throw UnimplementedError();

Future<ToolExecutionResult> _unusedExecutor(_, _, _) async =>
    ToolExecutionResult.text('unused');

RedactionPipeline _pipeline({
  RedactionConfig config = const RedactionConfig(),
}) {
  return RedactionPipeline(registeredSecrets: [_ghp], config: config);
}

AssistantMessage _assistant({List<ContentBlock> content = const []}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolCall _call(String name, Map<String, dynamic> args) =>
    ToolCall(id: 'call-1', name: name, arguments: args);

AfterToolCallContext _afterContext(ToolCall call, ToolExecutionResult result) {
  return AfterToolCallContext(
    assistantMessage: _assistant(content: [call]),
    toolCall: call,
    result: result,
    isError: false,
    context: const Context(messages: []),
  );
}

BeforeToolCallContext _beforeContext(ToolCall call) {
  return BeforeToolCallContext(
    assistantMessage: _assistant(content: [call]),
    toolCall: call,
    context: const Context(messages: []),
  );
}

ToolResultMessage _toolResult(String name, String text) {
  return ToolResultMessage(
    toolCallId: 'call-1',
    toolName: name,
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

void main() {
  group('isRedactionExemptTool', () {
    test('write-side built-ins are exempt (issue #24 AC7)', () {
      expect(isRedactionExemptTool('write'), isTrue);
      expect(isRedactionExemptTool('edit'), isTrue);
      expect(isRedactionExemptTool('checkpoint'), isTrue);
    });

    test('MCP write-ish tools are exempt, read tools are not', () {
      expect(isRedactionExemptTool('mcp__fs__write_file'), isTrue);
      expect(isRedactionExemptTool('read'), isFalse);
      expect(isRedactionExemptTool('mcp__fs__read_file'), isFalse);
      expect(isRedactionExemptTool('bash'), isFalse);
    });
  });

  group('isCredentialFilePath', () {
    test('credential files', () {
      expect(isCredentialFilePath('.env'), isTrue);
      expect(isCredentialFilePath('.env.local'), isTrue);
      expect(isCredentialFilePath('~/.ssh/id_rsa'), isTrue);
      expect(isCredentialFilePath('/home/u/.ssh/id_ed25519'), isTrue);
      expect(isCredentialFilePath('~/.aws/credentials'), isTrue);
      expect(isCredentialFilePath('.npmrc'), isTrue);
      expect(isCredentialFilePath('.netrc'), isTrue);
      expect(isCredentialFilePath('~/.docker/config.json'), isTrue);
      expect(isCredentialFilePath('certs/server.pem'), isTrue);
      expect(isCredentialFilePath('keys/app.key'), isTrue);
    });

    test('ordinary files are not credentials', () {
      expect(isCredentialFilePath('lib/main.dart'), isFalse);
      expect(isCredentialFilePath('config.json'), isFalse);
      expect(isCredentialFilePath('credentials'), isFalse);
      expect(isCredentialFilePath('test/fixtures/env.txt'), isFalse);
    });
  });

  group('credentialPathOf', () {
    test('read path argument', () {
      expect(credentialPathOf(_call('read', {'path': '.env'})), '.env');
      expect(credentialPathOf(_call('read', {'path': 'README.md'})), isNull);
    });

    test('bash credential read command', () {
      expect(
        credentialPathOf(_call('bash', {'command': 'cat ~/.ssh/id_rsa'})),
        isNotNull,
      );
      expect(
        credentialPathOf(_call('bash', {'command': 'cat README.md'})),
        isNull,
      );
    });
  });

  group('redactionPipelineHooks.afterToolCall', () {
    test('masks vendor keys in tool results and records stats', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(pipeline);
      final call = _call('read', {'path': 'src/config.dart'});
      final result = await hooks.afterToolCall(
        _afterContext(
          call,
          ToolExecutionResult(content: [TextContent(text: 'token=$_ghp;')]),
        ),
        null,
      );
      expect(result, isNotNull);
      final text = (result!.content!.single as TextContent).text;
      expect(text.contains(_ghp), isFalse);
      expect(text, contains('[REDACTED:'));
      expect(pipeline.stats.byTool['read'], 1);
    });

    test('passes the read path as the path hint (whole-file dumps)', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(pipeline);
      final call = _call('read', {'path': '.env'});
      final result = await hooks.afterToolCall(
        _afterContext(
          call,
          ToolExecutionResult(
            content: [TextContent(text: 'APP_ENV=prod\nSMTP_PASSWORD=hunter2')],
          ),
        ),
        null,
      );
      final text = (result!.content!.single as TextContent).text;
      expect(text.contains('hunter2'), isFalse);
    });

    test('write-side tool results are never redacted (AC7)', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(pipeline);
      final call = _call('write', {'path': 'lib/a.dart'});
      final raw = 'const token = "$_ghp";';
      final result = await hooks.afterToolCall(
        _afterContext(
          call,
          ToolExecutionResult(content: [TextContent(text: raw)]),
        ),
        null,
      );
      expect(result, isNull);
      expect(pipeline.stats.byTool['write'], isNull);
    });

    test('tool policy deny skips the tool', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(
        pipeline,
        policy: RedactionToolPolicy(deny: {'read'}),
      );
      final call = _call('read', {'path': 'src/config.dart'});
      final result = await hooks.afterToolCall(
        _afterContext(
          call,
          ToolExecutionResult(content: [TextContent(text: 'token=$_ghp;')]),
        ),
        null,
      );
      expect(result, isNull);
    });

    test('untouched content returns null (no override)', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(pipeline);
      final call = _call('read', {'path': 'README.md'});
      final result = await hooks.afterToolCall(
        _afterContext(
          call,
          ToolExecutionResult(content: [TextContent(text: 'hello world')]),
        ),
        null,
      );
      expect(result, isNull);
    });
  });

  group('redactionPipelineHooks.beforeToolCall (blockMode, AC6)', () {
    test('blocks a read of a credential file', () async {
      final pipeline = _pipeline(
        config: const RedactionConfig(blockMode: true),
      );
      final hooks = redactionPipelineHooks(pipeline);
      final result = await hooks.beforeToolCall(
        _beforeContext(_call('read', {'path': '.env'})),
        null,
      );
      expect(result?.block, isTrue);
      expect(result?.reason, contains('.env'));
    });

    test('blocks a bash cat of a private key', () async {
      final pipeline = _pipeline(
        config: const RedactionConfig(blockMode: true),
      );
      final hooks = redactionPipelineHooks(pipeline);
      final result = await hooks.beforeToolCall(
        _beforeContext(_call('bash', {'command': 'cat ~/.ssh/id_rsa'})),
        null,
      );
      expect(result?.block, isTrue);
    });

    test('ordinary reads pass in blockMode', () async {
      final pipeline = _pipeline(
        config: const RedactionConfig(blockMode: true),
      );
      final hooks = redactionPipelineHooks(pipeline);
      final result = await hooks.beforeToolCall(
        _beforeContext(_call('read', {'path': 'lib/main.dart'})),
        null,
      );
      expect(result, isNull);
    });

    test('mask mode never blocks (default)', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(pipeline);
      final result = await hooks.beforeToolCall(
        _beforeContext(_call('read', {'path': '.env'})),
        null,
      );
      expect(result, isNull);
    });
  });

  group('redactionPipelineHooks.transformContext', () {
    test('masks user messages (prompt echo path)', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(pipeline);
      final messages = await hooks.transformContext([
        UserMessage(
          content: 'my token is $_ghp, fix it',
          timestamp: DateTime.utc(2026),
        ),
      ], null);
      final text = (messages.single as UserMessage).content as String;
      expect(text.contains(_ghp), isFalse);
      expect(pipeline.stats.byTool['user_input'], 1);
    });

    test('write-side tool results survive byte-identical (AC7)', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(pipeline);
      final raw = 'const token = "$_ghp";';
      final messages = await hooks.transformContext([
        _toolResult('write', raw),
      ], null);
      expect(
        ((messages.single as ToolResultMessage).content.single as TextContent)
            .text,
        raw,
      );
    });

    test('masks read tool results and assistant text', () async {
      final pipeline = _pipeline();
      final hooks = redactionPipelineHooks(pipeline);
      final messages = await hooks.transformContext([
        _toolResult('read', 'token=$_ghp;'),
        _assistant(content: [TextContent(text: 'found $_ghp')]),
      ], null);
      final toolText =
          ((messages[0] as ToolResultMessage).content.single as TextContent)
              .text;
      final assistantText =
          ((messages[1] as AssistantMessage).content.single as TextContent)
              .text;
      expect(toolText.contains(_ghp), isFalse);
      expect(assistantText.contains(_ghp), isFalse);
    });
  });

  group('redactPrompt (AC8)', () {
    test('masks and counts under user_input', () {
      final pipeline = _pipeline();
      final out = redactPrompt(pipeline, 'use $_ghp please');
      expect(out.contains(_ghp), isFalse);
      expect(out, contains('[REDACTED:'));
      expect(pipeline.stats.byTool['user_input'], 1);
    });

    test('clean prompt returns unchanged', () {
      final pipeline = _pipeline();
      expect(redactPrompt(pipeline, 'hello'), 'hello');
    });
  });

  group('attachRedactionPipeline', () {
    test('existing afterToolCall output is redacted afterwards', () async {
      final pipeline = _pipeline();
      final agent = Agent(
        streamFunction: _neverStream,
        toolExecutor: _unusedExecutor,
        afterToolCall: (context, cancelToken) async {
          return AfterToolCallResult(
            content: [TextContent(text: 'echo ${context.toolCall.name}')],
          );
        },
      );
      attachRedactionPipeline(agent, pipeline);
      final call = _call('read', {'path': 'x.dart'});
      final result = await agent.afterToolCall!(
        _afterContext(call, ToolExecutionResult(content: const [])),
        null,
      );
      // The prior hook's text contains no secret, but must survive.
      final text = (result!.content!.single as TextContent).text;
      expect(text, 'echo read');
    });

    test('prior hook result carrying a secret gets masked', () async {
      final pipeline = _pipeline();
      final agent = Agent(
        streamFunction: _neverStream,
        toolExecutor: _unusedExecutor,
        afterToolCall: (context, cancelToken) async {
          return AfterToolCallResult(
            content: [TextContent(text: 'leak=$_ghp')],
          );
        },
      );
      attachRedactionPipeline(agent, pipeline);
      final call = _call('read', {'path': 'x.dart'});
      final result = await agent.afterToolCall!(
        _afterContext(call, ToolExecutionResult(content: const [])),
        null,
      );
      final text = (result!.content!.single as TextContent).text;
      expect(text.contains(_ghp), isFalse);
    });

    test('existing beforeToolCall block verdict wins', () async {
      final pipeline = _pipeline(
        config: const RedactionConfig(blockMode: true),
      );
      final agent = Agent(
        streamFunction: _neverStream,
        toolExecutor: _unusedExecutor,
        beforeToolCall: (context, cancelToken) =>
            const BeforeToolCallResult(block: true, reason: 'policy'),
      );
      attachRedactionPipeline(agent, pipeline);
      final result = await agent.beforeToolCall!(
        _beforeContext(_call('read', {'path': '.env'})),
        null,
      );
      expect(result?.block, isTrue);
      expect(result?.reason, 'policy');
    });

    test('redaction block applies when no prior hook blocks', () async {
      final pipeline = _pipeline(
        config: const RedactionConfig(blockMode: true),
      );
      final agent = Agent(
        streamFunction: _neverStream,
        toolExecutor: _unusedExecutor,
      );
      attachRedactionPipeline(agent, pipeline);
      final result = await agent.beforeToolCall!(
        _beforeContext(_call('bash', {'command': 'cat .env'})),
        null,
      );
      expect(result?.block, isTrue);
      expect(result?.reason, contains('redact.blockMode'));
    });

    test('transformContext composition masks the composed list', () async {
      final pipeline = _pipeline();
      final agent = Agent(
        streamFunction: _neverStream,
        toolExecutor: _unusedExecutor,
        transformContext: (messages, cancelToken) async => [
          UserMessage(content: 'prefixed', timestamp: DateTime.utc(2026)),
        ],
      );
      attachRedactionPipeline(agent, pipeline);
      final messages = await agent.transformContext!([
        UserMessage(content: 'token=$_ghp', timestamp: DateTime.utc(2026)),
      ], null);
      final text = (messages.single as UserMessage).content as String;
      expect(text, 'prefixed');
    });
  });
}
