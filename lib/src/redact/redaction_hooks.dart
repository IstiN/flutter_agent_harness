import 'package:flutter_agent_harness/src/agent/agent.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/types.dart';

import 'redaction_pipeline.dart';

/// Tool outputs that are model-authored: their content is the code/config
/// the MODEL produced, so key-shaped strings in them are the deliverable,
/// not leaks. Never redacted (issue #24 AC7, mirroring pi-redact-all's
/// scoped hooks).
const redactionExemptTools = {'write', 'edit', 'checkpoint'};

/// True when [name]'s output must never be redacted: the built-in
/// model-authored tools, or an MCP tool whose name contains a write-ish
/// segment (`mcp__server__write_file`).
bool isRedactionExemptTool(String name) =>
    redactionExemptTools.contains(name) ||
    (name.startsWith('mcp__') && name.contains('write'));

/// Basename-style credential files the path layer recognizes for
/// [blockMode] blocking (issue #24 L7 / AC6).
const _credentialBasenames = {
  '.env',
  'id_rsa',
  'id_ed25519',
  'id_ecdsa',
  'credentials',
  '.npmrc',
  '.netrc',
  'config.json',
};

/// True when [path] points at a credential file: its basename is one of
/// [_credentialBasenames] (with `config.json` only counting under a
/// `.docker` directory), or it is a `.env.*` variant.
bool isCredentialFilePath(String path) {
  final normalized = path.replaceFirst('^~/', '/').toLowerCase();
  final segments = normalized.split('/');
  final basename = segments.last;
  if (basename == '.env' || basename.startsWith('.env.')) return true;
  if (_credentialBasenames.contains(basename)) {
    // `config.json` is only a credential under `.docker/`; `credentials`
    // only under `.aws/` (or as an explicit name on its own).
    if (basename == 'config.json') {
      return segments.length >= 2 && segments[segments.length - 2] == '.docker';
    }
    if (basename == 'credentials') {
      return segments.length >= 2 && segments[segments.length - 2] == '.aws';
    }
    return true;
  }
  if (basename.endsWith('.pem') || basename.endsWith('.key')) return true;
  return false;
}

/// Read-ish commands whose first path argument is checked against
/// [isCredentialFilePath] (`cat ~/.ssh/id_rsa`, `cat .env`, ...).
final RegExp _bashReadCommand = RegExp(
  r'''(?:cat|less|more|head|tail|vi|vim|nano|source)\s+(?:--?\S+\s+)*(\S+)''',
  caseSensitive: false,
);

/// Extracts the credential file a bash command is about to read, if any.
String? _bashCredentialReadPath(String command) {
  final match = _bashReadCommand.firstMatch(command);
  if (match == null) return null;
  final path = match.group(1)!.replaceAll(RegExp('["\']'), '');
  return isCredentialFilePath(path) ? path : null;
}

/// The [ToolCall.arguments] keys tools use for a file path.
const _pathArgKeys = ['path', 'file_path', 'filePath'];

/// Extracts the credential path a tool call is about to touch, if any.
String? credentialPathOf(ToolCall call) {
  for (final key in _pathArgKeys) {
    final value = call.arguments[key];
    if (value is String && isCredentialFilePath(value)) return value;
  }
  if (call.name == 'bash') {
    final command = call.arguments['command'];
    if (command is String) return _bashCredentialReadPath(command);
  }
  return null;
}

/// The hook set the redaction pipeline installs on an [Agent]; see
/// [redactionPipelineHooks] and [attachRedactionPipeline].
typedef RedactionPipelineHooks = ({
  BeforeToolCallHook beforeToolCall,
  AfterToolCallHook afterToolCall,
  TransformContextHook transformContext,
});

/// Per-tool redaction policy (issue #24 `redact.toolPolicy`): when
/// [allow] is non-empty only those tools are redacted; [deny] always wins.
class RedactionToolPolicy {
  RedactionToolPolicy({
    Set<String> allow = const {},
    Set<String> deny = const {},
  }) : allow = Set.unmodifiable(allow),
       deny = Set.unmodifiable(deny);

  /// Only these tools are redacted (empty = all).
  final Set<String> allow;

  /// These tools are never redacted (wins over [allow]).
  final Set<String> deny;

  bool appliesTo(String toolName) =>
      !deny.contains(toolName) && (allow.isEmpty || allow.contains(toolName));
}

/// Builds the agent hooks for the layered pipeline:
///
/// - `afterToolCall` masks tool result text (unless the tool is
///   write-side-exempt or filtered out by [policy]) before it enters the
///   transcript — so the session JSONL carries masked text, never the raw
///   secret. The tool's file-path argument (for `read`-family calls) is
///   passed as the pipeline's path hint so the path layer can protect a
///   whole credential-file dump.
/// - `transformContext` is the belt-and-braces pass over the outgoing
///   message list: user messages and any tool result that bypassed
///   `afterToolCall` get masked; write-side-exempt tool results stay
///   byte-identical (AC7).
/// - `beforeToolCall` implements `blockMode`: a `read`/`bash` call that
///   would touch a credential file is denied with a human reason (AC6).
///   In mask mode (default) it never blocks.
///
/// Every redaction is counted in [RedactionPipeline.stats] under the tool
/// name (`user_input` for prompt redaction via [redactPrompt]).
RedactionPipelineHooks redactionPipelineHooks(
  RedactionPipeline pipeline, {
  RedactionToolPolicy policy = const _ConstPolicy(),
}) {
  BeforeToolCallResult? beforeToolCall(
    BeforeToolCallContext context,
    CancelToken? cancelToken,
  ) {
    if (!pipeline.config.blockMode) return null;
    final path = credentialPathOf(context.toolCall);
    if (path == null) return null;
    return BeforeToolCallResult(
      block: true,
      reason:
          'Blocked by redaction: "$path" is a credential file '
          '(redact.blockMode). Allow-list it in the redact config if this '
          'read is intentional.',
    );
  }

  AfterToolCallResult? afterToolCall(
    AfterToolCallContext context,
    CancelToken? cancelToken,
  ) {
    final toolName = context.toolCall.name;
    if (isRedactionExemptTool(toolName) || !policy.appliesTo(toolName)) {
      return null;
    }
    final pathHint = _pathHintOf(context.toolCall);
    var changed = false;
    final content = [
      for (final block in context.result.content)
        _redactBlock(pipeline, block, pathHint, onChange: () => changed = true),
    ];
    if (!changed) return null;
    pipeline.stats.record(toolName);
    return AfterToolCallResult(content: content);
  }

  List<Message> transformContext(
    List<Message> messages,
    CancelToken? cancelToken,
  ) {
    return [
      for (final message in messages) _redactMessage(pipeline, message, policy),
    ];
  }

  return (
    beforeToolCall: beforeToolCall,
    afterToolCall: afterToolCall,
    transformContext: transformContext,
  );
}

/// Masks secrets in [prompt] before it reaches the provider/session
/// (issue #24 AC8). Counted under the `user_input` tool name.
String redactPrompt(RedactionPipeline pipeline, String prompt) {
  final redacted = pipeline.redact(prompt);
  if (redacted != prompt) pipeline.stats.record('user_input');
  return redacted;
}

/// Composes the pipeline hooks onto [agent], preserving hooks already
/// registered. `beforeToolCall`: existing hooks run first; if any of them
/// blocks, that verdict stands. `afterToolCall`/`transformContext`:
/// existing hooks run first, redaction runs last so content they produce
/// is masked too.
// ignore: long-method
void attachRedactionPipeline(
  Agent agent,
  RedactionPipeline pipeline, {
  RedactionToolPolicy policy = const _ConstPolicy(),
}) {
  final hooks = redactionPipelineHooks(pipeline, policy: policy);

  final existingBefore = agent.beforeToolCall;
  agent.beforeToolCall = (context, cancelToken) async {
    if (existingBefore != null) {
      final prior = await existingBefore(context, cancelToken);
      if (prior != null && prior.block) return prior;
    }
    return hooks.beforeToolCall(context, cancelToken);
  };

  final existingAfter = agent.afterToolCall;
  agent.afterToolCall = (context, cancelToken) async {
    final prior = existingAfter == null
        ? null
        : await existingAfter(context, cancelToken);
    final rawResult = context.result;
    final effectiveContent = prior?.content ?? rawResult.content;
    final effectiveContext = AfterToolCallContext(
      assistantMessage: context.assistantMessage,
      toolCall: context.toolCall,
      result: ToolExecutionResult(content: effectiveContent),
      isError: context.isError,
      context: context.context,
    );
    // `await` flattens the hook's FutureOr<AfterToolCallResult?>.
    final ours = await hooks.afterToolCall(effectiveContext, cancelToken);
    if (ours == null && prior == null) return null;
    return AfterToolCallResult(
      content: ours?.content ?? prior?.content ?? context.result.content,
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

/// Non-redacting default policy (all tools apply).
class _ConstPolicy implements RedactionToolPolicy {
  const _ConstPolicy();

  @override
  Set<String> get allow => const {};

  @override
  Set<String> get deny => const {};

  @override
  bool appliesTo(String toolName) => true;
}

String? _pathHintOf(ToolCall call) {
  if (call.name != 'read' && call.name != 'bash') return null;
  for (final key in _pathArgKeys) {
    final value = call.arguments[key];
    if (value is String && value.isNotEmpty) return value;
  }
  if (call.name == 'bash') {
    final command = call.arguments['command'];
    if (command is String) return _bashCredentialReadPath(command);
  }
  return null;
}

ContentBlock _redactBlock(
  RedactionPipeline pipeline,
  ContentBlock block,
  String? pathHint, {
  void Function()? onChange,
}) {
  if (block is TextContent) {
    final text = pipeline.redact(block.text, pathHint: pathHint);
    if (text == block.text) return block;
    onChange?.call();
    return block.copyWith(text: text);
  }
  if (block is ThinkingContent) {
    final thinking = pipeline.redact(block.thinking);
    if (thinking == block.thinking) return block;
    onChange?.call();
    return block.copyWith(thinking: thinking);
  }
  return block;
}

/// Redacts a block list, reporting whether anything changed.
(List<ContentBlock>, bool) _redactBlocks(
  RedactionPipeline pipeline,
  List<ContentBlock> blocks,
  String? pathHint,
) {
  var changed = false;
  final redacted = [
    for (final block in blocks)
      _redactBlock(pipeline, block, pathHint, onChange: () => changed = true),
  ];
  return (redacted, changed);
}

UserMessage _redactUserMessage(
  RedactionPipeline pipeline,
  UserMessage message,
) {
  final content = message.content;
  if (content is String) {
    final text = redactPrompt(pipeline, content);
    return text == content
        ? message
        : UserMessage(content: text, timestamp: message.timestamp);
  }
  final (blocks, changed) = _redactBlocks(
    pipeline,
    content as List<ContentBlock>,
    null,
  );
  return changed
      ? UserMessage(content: blocks, timestamp: message.timestamp)
      : message;
}

ToolResultMessage _redactToolResult(
  RedactionPipeline pipeline,
  ToolResultMessage message,
  RedactionToolPolicy policy,
) {
  if (isRedactionExemptTool(message.toolName) ||
      !policy.appliesTo(message.toolName)) {
    return message;
  }
  final (blocks, changed) = _redactBlocks(pipeline, message.content, null);
  if (!changed) return message;
  pipeline.stats.record(message.toolName);
  return ToolResultMessage(
    toolCallId: message.toolCallId,
    toolName: message.toolName,
    content: blocks,
    isError: message.isError,
    timestamp: message.timestamp,
  );
}

Message _redactMessage(
  RedactionPipeline pipeline,
  Message message,
  RedactionToolPolicy policy,
) {
  switch (message) {
    case UserMessage():
      return _redactUserMessage(pipeline, message);
    case ToolResultMessage():
      return _redactToolResult(pipeline, message, policy);
    case AssistantMessage():
      final (blocks, changed) = _redactBlocks(pipeline, message.content, null);
      return changed ? message.copyWith(content: blocks) : message;
    default:
      return message;
  }
}
