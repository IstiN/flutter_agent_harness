/// Bridges the harness's streaming contract onto fa_llm's [LlmProvider] —
/// the interface `flutter_agent_memory` consumes for semantic search and
/// `consolidate()`. Without this adapter the memory controller runs
/// keyword-only search and skips consolidation entirely.
///
/// The slot (stream + model) is resolved PER CALL through the injected
/// [resolve] callback: the model-roles resolver is mutable (the CLI's
/// `/settings` can pin role chains mid-session), so caching a resolved
/// model here would go stale. Hosts resolve the `memory` role first, then
/// `smol`, then the main model.
library;

import 'package:flutter_agent_memory/flutter_agent_memory.dart';

import '../agent/agent_loop.dart';
import '../context.dart';
import '../model.dart';
import '../types.dart';

/// One resolved LLM slot: the stream function and the model for a call.
typedef HarnessLlmSlot = ({Model model, StreamFunction stream});

/// An [LlmProvider] over the harness [StreamFunction] contract. `extends`
/// (not `implements`) so the interface's default `chatStream` /
/// `chatMessagesStream` / `cancel` bodies carry over.
final class HarnessLlmProvider extends LlmProvider {
  HarnessLlmProvider({required this.resolve});

  /// Resolves the slot for each call (the roles resolver is mutable).
  final HarnessLlmSlot? Function() resolve;

  @override
  String get defaultModel => resolve()?.model.id ?? 'unknown';

  @override
  Future<String> chat(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) => chatMessages(
    [LlmMessage(role: 'user', content: prompt)],
    model: model,
    onCancel: onCancel,
  );

  /// Sends the conversation and returns the generated text. The [model]
  /// override is ignored — the resolved role slot is authoritative (it
  /// carries the endpoint and the key, not just the id). Images on
  /// [LlmMessage]s are dropped: the memory paths are text-only.
  @override
  Future<String> chatMessages(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) async {
    final slot = resolve();
    if (slot == null) {
      onCancel?.call();
      throw StateError(
        'HarnessLlmProvider: no LLM slot resolved (roles unavailable)',
      );
    }
    final systemParts = <String>[];
    final mapped = <Message>[];
    for (final m in messages) {
      switch (m.role) {
        case 'system':
          systemParts.add(m.content);
        case 'assistant':
          mapped.add(
            AssistantMessage(
              content: [TextContent(text: m.content)],
              api: slot.model.api,
              provider: slot.model.provider,
              model: slot.model.id,
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: DateTime.fromMillisecondsSinceEpoch(0),
            ),
          );
        default:
          mapped.add(UserMessage.text(m.content));
      }
    }
    final response = await slot
        .stream(
          slot.model,
          Context(
            systemPrompt: systemParts.isEmpty ? null : systemParts.join('\n\n'),
            messages: mapped,
          ),
        )
        .result;
    if (response.stopReason == StopReason.error ||
        response.stopReason == StopReason.aborted) {
      onCancel?.call();
      throw StateError(
        'HarnessLlmProvider: stream ended with '
        '${response.stopReason.name}: ${response.errorMessage ?? '-'}',
      );
    }
    return response.content
        .whereType<TextContent>()
        .map((block) => block.text)
        .join('\n')
        .trim();
  }
}
