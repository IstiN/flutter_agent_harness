// Live GLM (z.ai) provider suite — the owner-designated live-LLM gate.
//
// GLM exposes an OpenAI-compatible endpoint, so the openai-completions
// adapter is exercised end-to-end against a real model. The key resolves
// exactly like production: `FA_KEY_API_Z_AI_Z_AI` in the environment, else
// the platform SecureKeyStore (macOS Keychain, service `fah`). Without a
// resolvable key every test skips gracefully — the suite must stay green on
// hosts that have no GLM credentials.
//
// Region/provider restrictions surface as ErrorEvents (providers never
// throw); the tests vacuously pass with a loud note when the upstream
// rejects the calling region, mirroring provider_openrouter_test.dart.
@Tags(['integration', 'llm'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/secrets/secure_key_store_io.dart';
import 'package:test/test.dart';

final _apiKey = () {
  final fromEnv = Platform.environment['FA_KEY_API_Z_AI_Z_AI'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return null;
}();

final _skip = (_apiKey?.isEmpty ?? true)
    ? 'FA_KEY_API_Z_AI_Z_AI not set and Keychain store unavailable'
    : false;

/// Cheap coding model on the z.ai OpenAI-compatible endpoint.
const _model = Model(
  id: 'glm-5.3-flash',
  name: 'GLM 5.3 Flash (z.ai)',
  api: 'openai-completions',
  provider: 'z.ai',
  baseUrl: 'https://api.z.ai/api/coding/paas/v4',
  contextWindow: 128000,
  maxTokens: 16384,
);

/// Trivial tool used to exercise tool-call streaming against the live API.
const _addTool = Tool(
  name: 'add',
  description: 'Add two numbers and return their sum.',
  parameters: {
    'type': 'object',
    'properties': {
      'a': {'type': 'number', 'description': 'First addend.'},
      'b': {'type': 'number', 'description': 'Second addend.'},
    },
    'required': ['a', 'b'],
    'additionalProperties': false,
  },
);

/// Upstream region/permission blocks arrive as terminal ErrorEvents whose
/// payload names the restriction; such an environment restriction is not an
/// adapter failure — the test passes vacuously with a loud note.
bool _isRegionBlock(Object? error) =>
    '$error'.contains('unsupported_country_region_territory');

bool _regionBlockedIn(Iterable<Object?> events) => events.any(_isRegionBlock);

void _noteRegionBlock() {
  // ignore: avoid_print
  print('⏭️ upstream provider rejects this region (403 '
      'unsupported_country_region_territory) — vacuous pass');
}

Future<String?> _resolveKey() async {
  if (_apiKey != null) return _apiKey;
  try {
    final store = platformSecureKeyStore();
    if (!await store.isAvailable()) return null;
    return await store.read('FA_KEY_API_Z_AI_Z_AI');
  } on Object {
    return null;
  }
}

Future<void> main() async {
  final key = await _resolveKey();
  final effectiveSkip = key == null ? _skip : false;

  group('GLM via z.ai (openai-completions adapter, live)', () {
    test(
      'streams incremental text deltas, a done event, and non-zero usage',
      () async {
        final stream = streamOpenAICompletions(
          _model,
          Context(messages: [UserMessage.text('Say hello in three words.')]),
          OpenAICompletionsOptions(
            apiKey: key,
            maxTokens: 64,
          ),
        );

        final events = await stream.toList();
        if (_regionBlockedIn(events)) {
          _noteRegionBlock();
          return;
        }
        expect(events.first, isA<StartEvent>());

        final deltas = events.whereType<TextDeltaEvent>().toList();
        expect(deltas, isNotEmpty, reason: 'expected at least one text delta');
        final fullText = deltas.map((delta) => delta.delta).join();
        expect(fullText.trim(), isNotEmpty);
        expect(fullText.startsWith(deltas.first.delta), isTrue);

        final done = events.last;
        expect(done, isA<DoneEvent>());
        final doneEvent = done as DoneEvent;
        expect(doneEvent.reason, isNot(StopReason.error));
        expect(doneEvent.reason, StopReason.stop);

        final message = await stream.result;
        expect(message.stopReason, doneEvent.reason);
        expect(message.usage.totalTokens, greaterThan(0));
        expect(message.usage.output, greaterThan(0));
      },
      skip: effectiveSkip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'streams a forced add() tool call with parsed arguments',
      () async {
        final stream = streamOpenAICompletions(
          _model,
          Context(
            messages: [UserMessage.text('Use the add tool to compute 40 + 2.')],
            tools: const [_addTool],
          ),
          OpenAICompletionsOptions(
            apiKey: key,
            maxTokens: 256,
            toolChoice: 'required',
          ),
        );

        final events = await stream.toList();
        if (_regionBlockedIn(events)) {
          _noteRegionBlock();
          return;
        }
        expect(events.whereType<ToolCallStartEvent>(), isNotEmpty);
        expect(events.whereType<ToolCallDeltaEvent>(), isNotEmpty);

        final end = events.whereType<ToolCallEndEvent>().single;
        expect(end.toolCall.name, 'add');
        expect(end.toolCall.id, isNotEmpty);
        final args = end.toolCall.arguments;
        expect((args['a'] as num) + (args['b'] as num), 42);

        final done = events.last;
        expect(done, isA<DoneEvent>());
        expect((done as DoneEvent).reason, StopReason.toolUse);
      },
      skip: effectiveSkip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'drives one full tool round-trip through the agent loop',
      () async {
        AssistantMessageEventStream streamFunction(
          Model model,
          Context context, {
          CancelToken? cancelToken,
        }) {
          return streamOpenAICompletions(
            model,
            context,
            OpenAICompletionsOptions(
              apiKey: key,
              maxTokens: 512,
              cancelToken: cancelToken,
            ),
          );
        }

        var executorCalls = 0;
        final agent = Agent(
          model: _model,
          systemPrompt:
              'You are a calculator. Always use the add tool for '
              'arithmetic, then answer with just the resulting number.',
          tools: const [_addTool],
          streamFunction: streamFunction,
          toolExecutor: (toolCall, cancelToken, onUpdate) async {
            executorCalls++;
            expect(toolCall.name, 'add');
            final args = toolCall.arguments;
            final sum = (args['a'] as num) + (args['b'] as num);
            return ToolExecutionResult.text('$sum');
          },
        );

        await agent.prompt('What is 40 + 2?');
        await agent.waitForIdle();

        if (_isRegionBlock(agent.state.errorMessage)) {
          _noteRegionBlock();
          return;
        }
        expect(agent.state.errorMessage, isNull);
        expect(executorCalls, 1);

        final messages = agent.state.messages;
        final toolResults = messages.whereType<ToolResultMessage>().toList();
        expect(toolResults, hasLength(1));
        final resultText = toolResults.single.content
            .whereType<TextContent>()
            .map((content) => content.text)
            .join();
        expect(resultText, contains('42'));

        final last = messages.last;
        expect(last, isA<AssistantMessage>());
        final lastAssistant = last as AssistantMessage;
        expect(lastAssistant.stopReason, StopReason.stop);
        final answer = lastAssistant.content
            .whereType<TextContent>()
            .map((content) => content.text)
            .join();
        expect(answer, contains('42'));
      },
      skip: effectiveSkip,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
