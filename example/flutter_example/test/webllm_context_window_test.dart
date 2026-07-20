import 'package:flutter_agent_example/prompts.g.dart';
import 'package:flutter_agent_example/sandbox_registry.dart';
import 'package:flutter_agent_example/secrets_store.dart';
import 'package:flutter_agent_example/webllm/webllm_stream_function.dart';
import 'package:flutter_agent_example/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures the exact messages the WebLLM stream function would hand the
/// engine, so tests can measure the engine-visible system prompt (sandbox
/// prompt + prompt-tools instructions) instead of guessing its size.
final class _CaptureEngine implements WebLlmEngineApi {
  List<WebLlmChatMessage>? lastMessages;

  @override
  bool get isAvailable => true;

  @override
  String? get loadedModelId => null;

  @override
  Stream<WebLlmProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(WebLlmModelPreset preset) async {}

  @override
  Future<void Function()> chatStream({
    required List<WebLlmChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  }) async {
    lastMessages = messages;
    onDone?.call('stop');
    return () {};
  }

  @override
  Future<void> interrupt() async {}

  @override
  Future<WebLlmCacheInfo?> modelCacheInfo(String modelId) async => null;

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}

/// Renders the system prompt exactly as the web build's engine sees it:
/// the sandbox prompt with the WEB command section, wrapped by the
/// prompt-tools instructions for the app's real tool set (builtin tools +
/// web search + ask), through the actual stream-function pipeline.
Future<String> _engineVisibleSystemPrompt() async {
  final env = MemoryExecutionEnv();
  final model = Model(
    id: webLlmModelPresets.first.id,
    name: webLlmModelPresets.first.id,
    api: webLlmProviderKind,
    provider: webLlmProviderKind,
    baseUrl: '',
    contextWindow: webLlmModelPresets.first.contextWindow,
    maxTokens: 1024,
  );
  final tools = [
    ...builtinTools(
      env,
      webSearch: WebSearchConfig(secrets: createSecretsStore()),
      model: () => model,
    ),
    askTool(),
  ];
  final rendered = sandboxSystemPrompt.replaceAll(
    '{{commands}}',
    formatSandboxCommandSection(SandboxPlatform.web),
  );
  final engine = _CaptureEngine();
  await webLlmStreamFunction(engine)(
    model,
    Context(
      systemPrompt: rendered,
      messages: [UserMessage.text('hi')],
      tools: tools,
    ),
  ).toList();
  return engine.lastMessages!.first.content;
}

/// Token count by the same 4-chars/token heuristic the compaction trigger
/// uses ([estimateTokens]) — conservative, so tests sized by it hold for the
/// engine's real tokenizer too.
int _estimateTokens(String text) => estimateTokens(UserMessage.text(text));

void main() {
  group('WebLLM engine-visible system prompt', () {
    test('covers the sandbox prompt and the tool instructions, within the '
        'documented envelope', () async {
      final system = await _engineVisibleSystemPrompt();
      // Both halves must be present for the measurement to mean anything.
      expect(system, contains('You are Fa'));
      expect(system, contains('## Available tools'));

      // Measured ~3.9k heuristic tokens (~3.3k engine tokens) with the
      // 8-tool set; the envelope trips if prompt growth ever approaches the
      // preset window instead of silently re-breaking on-device chat.
      final tokens = _estimateTokens(system);
      expect(tokens, greaterThan(3000), reason: 'tool block missing?');
      expect(tokens, lessThanOrEqualTo(4200), reason: 'prompt grew too large');
    });

    test('fits every preset window with headroom for several turns and the '
        'reply', () async {
      final systemTokens = _estimateTokens(await _engineVisibleSystemPrompt());
      // Headroom: user turns, tool call/result round-trips, and the
      // maxTokens=1024 reply cap the settings form sends.
      const neededHeadroom = 3000;
      for (final preset in webLlmModelPresets) {
        expect(
          preset.contextWindow - systemTokens,
          greaterThanOrEqualTo(neededHeadroom),
          reason:
              '${preset.id}: window ${preset.contextWindow} leaves only '
              '${preset.contextWindow - systemTokens} tokens next to a '
              '~$systemTokens-token system prompt',
        );
      }
    });
  });

  group('compaction scaling for the preset window', () {
    test(
      'fires before the engine overflows and leaves a fitting context',
      () async {
        final systemTokens = _estimateTokens(
          await _engineVisibleSystemPrompt(),
        );
        for (final preset in webLlmModelPresets) {
          // The AgentService rule: the conversation window is what remains
          // after the system prompt; thresholds scale with it.
          final conversationWindow = preset.contextWindow - systemTokens;
          final settings = CompactionSettings.forWindow(conversationWindow);

          // The trigger point (window minus reserve) must come before the
          // engine's hard overflow, so compaction runs while the next turn
          // would still fit.
          final triggerEngineTokens =
              conversationWindow - settings.reserveTokens + systemTokens;
          expect(
            triggerEngineTokens,
            lessThan(preset.contextWindow),
            reason:
                '${preset.id}: compaction would fire only after the '
                'engine already overflowed',
          );

          // After compaction the context (system + bounded summary + kept
          // recent region) must fit the window again, or the very next turn
          // overflows anyway. The summary call is capped by the app's
          // maxTokens=1024 for on-device presets.
          final compactedEngineTokens =
              systemTokens + 1024 + settings.keepRecentTokens;
          expect(
            compactedEngineTokens,
            lessThan(preset.contextWindow),
            reason: '${preset.id}: post-compaction context would not fit',
          );
        }
      },
    );

    test('reproduces pi defaults for hosted-model windows', () {
      // A 128k hosted model with a small system prompt: the scaling rule
      // must land exactly on pi's fixed defaults.
      final settings = CompactionSettings.forWindow(128000 - 1000);
      expect(settings.reserveTokens, 16384);
      expect(settings.keepRecentTokens, 20000);
    });
  });
}
