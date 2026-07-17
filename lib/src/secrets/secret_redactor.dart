/// Redaction of secret values (API keys, tokens) from agent-visible text.
///
/// Secrets must be usable as `$VARS` in sandbox shell commands without
/// leaking into the LLM context or onto disk in session files. A
/// [SecretRedactor] holds the secret values and masks them with `***` in
/// tool results (via [redactionHooks] / [attachSecretRedactor]) before they
/// enter the transcript, the provider context, or the session JSONL.
library;

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../types.dart';

/// Holds secret values and replaces them with [SecretRedactor.mask] in text.
///
/// Values shorter than [minValueLength] are never registered: short strings
/// (like `true` or `12345`) appear in normal output too often and masking
/// them would mangle unrelated text. Only names are ever exposed, never
/// values.
final class SecretRedactor {
  /// Creates an empty redactor; register values with [register].
  SecretRedactor();

  /// Creates a redactor pre-loaded with [secrets] (name → value).
  factory SecretRedactor.fromSecrets(Map<String, String> secrets) {
    return SecretRedactor()..registerAll(secrets);
  }

  /// Values shorter than this are ignored (false-positive guard).
  static const minValueLength = 8;

  /// The replacement text for a masked secret value.
  static const mask = '***';

  final Map<String, String> _values = {};

  /// The registered secret names, sorted. Values are never exposed.
  List<String> get names => _values.keys.toList()..sort();

  /// Whether no secret values are registered.
  bool get isEmpty => _values.isEmpty;

  /// Registers [value] under [name]; values shorter than [minValueLength]
  /// are ignored.
  void register(String name, String value) {
    if (value.length < minValueLength) return;
    _values[name] = value;
  }

  /// Registers every entry of [secrets]; see [register].
  void registerAll(Map<String, String> secrets) {
    secrets.forEach(register);
  }

  /// Replaces every registered secret value in [text] with [mask].
  String redact(String text) {
    if (_values.isEmpty || text.isEmpty) return text;
    var out = text;
    for (final value in _values.values) {
      if (out.contains(value)) out = out.replaceAll(value, mask);
    }
    return out;
  }
}

/// Agent hooks that mask registered secrets, see [redactionHooks].
typedef RedactionHooks = ({
  AfterToolCallHook afterToolCall,
  TransformContextHook transformContext,
});

/// Builds the agent hooks that redact [redactor]'s values:
///
/// - `afterToolCall` masks [TextContent] blocks of every tool result before
///   it enters the transcript (and therefore the session JSONL).
/// - `transformContext` masks text in the message list sent to the provider
///   (belt-and-braces: user messages, assistant text/thinking, and any tool
///   result that bypassed `afterToolCall`).
RedactionHooks redactionHooks(SecretRedactor redactor) {
  AfterToolCallResult? afterToolCall(
    AfterToolCallContext context,
    CancelToken? cancelToken,
  ) {
    var changed = false;
    final content = [
      for (final block in context.result.content)
        _redactBlock(redactor, block, onChange: () => changed = true),
    ];
    return changed ? AfterToolCallResult(content: content) : null;
  }

  List<Message> transformContext(
    List<Message> messages,
    CancelToken? cancelToken,
  ) {
    return [for (final message in messages) _redactMessage(redactor, message)];
  }

  return (afterToolCall: afterToolCall, transformContext: transformContext);
}

/// Composes the redaction hooks for [redactor] onto [agent], preserving any
/// hooks already registered (existing hooks run first, redaction runs last
/// so content they produce is masked too).
void attachSecretRedactor(Agent agent, SecretRedactor redactor) {
  final hooks = redactionHooks(redactor);

  final existingAfter = agent.afterToolCall;
  agent.afterToolCall = (context, cancelToken) async {
    final prior = existingAfter == null
        ? null
        : await existingAfter(context, cancelToken);
    final effectiveContent = prior?.content ?? context.result.content;
    var changed = false;
    final redactedContent = [
      for (final block in effectiveContent)
        _redactBlock(redactor, block, onChange: () => changed = true),
    ];
    if (prior == null && !changed) return null;
    return AfterToolCallResult(
      content: redactedContent,
      isError: prior?.isError,
      terminate: prior?.terminate,
    );
  };

  final existingTransform = agent.transformContext;
  agent.transformContext = (messages, cancelToken) async {
    final transformed = existingTransform == null
        ? messages
        : await existingTransform(messages, cancelToken);
    return hooks.transformContext(transformed, cancelToken);
  };
}

ContentBlock _redactBlock(
  SecretRedactor redactor,
  ContentBlock block, {
  void Function()? onChange,
}) {
  if (block is TextContent) {
    final text = redactor.redact(block.text);
    if (text == block.text) return block;
    onChange?.call();
    return block.copyWith(text: text);
  }
  if (block is ThinkingContent) {
    final thinking = redactor.redact(block.thinking);
    if (thinking == block.thinking) return block;
    onChange?.call();
    return block.copyWith(thinking: thinking);
  }
  return block;
}

Message _redactMessage(SecretRedactor redactor, Message message) {
  switch (message) {
    case UserMessage():
      final content = message.content;
      if (content is String) {
        final text = redactor.redact(content);
        return text == content
            ? message
            : UserMessage(content: text, timestamp: message.timestamp);
      }
      final blocks = [
        for (final block in content as List<ContentBlock>)
          _redactBlock(redactor, block),
      ];
      return UserMessage(content: blocks, timestamp: message.timestamp);
    case ToolResultMessage():
      return ToolResultMessage(
        toolCallId: message.toolCallId,
        toolName: message.toolName,
        content: [
          for (final block in message.content) _redactBlock(redactor, block),
        ],
        isError: message.isError,
        timestamp: message.timestamp,
      );
    case AssistantMessage():
      return message.copyWith(
        content: [
          for (final block in message.content) _redactBlock(redactor, block),
        ],
      );
    default:
      return message;
  }
}
