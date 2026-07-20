/// Universal prompt-based tool-calling wrapper.
///
/// Gives tool-calling capability to ANY chat-only model stream: wraps a
/// [StreamFunction], injects tool instructions into the system prompt (the
/// compiled `prompts/tools/tool_calling.md` template), parses tool calls out
/// of the plain-text output stream, and emits the harness tool-call event
/// contract ([ToolCallStartEvent] → [ToolCallDeltaEvent] →
/// [ToolCallEndEvent], [StopReason.toolUse]). Target users: providers without
/// native function calling (the WebLLM on-device provider, CLI chat-only
/// backends).
///
/// pi has no prompt-based tool-calling mode, so the wire format is designed
/// here (not ported): Markdown-fenced blocks, robust for small models, easy
/// to spot in streams, unambiguous in Markdown output.
///
/// Call format (assistant output):
///
///     ```tool_call
///     {"name": "shell", "arguments": {"cmd": "ls"}}
///     ```
///
/// Result format (fed back as a user message):
///
///     ```tool_result
///     tool: shell
///     error: true            ← only when the call failed
///
///     file1.txt
///     ```
///
/// Streaming parse (partial-first contract preserved):
///
/// - Text passes through as [TextDeltaEvent]s carrying full partial
///   snapshots, like the provider adapters.
/// - A potential fence opener may split across chunks: the longest suffix of
///   buffered text that is still a prefix of the opener is held back until it
///   resolves, so normal text never stalls longer than the marker length.
/// - Inside a `tool_call` block: buffer (capped at
///   [PromptToolOptions.maxBlockSize]; overflow emits the buffer as plain
///   text and resumes text mode).
/// - On block close: parse the JSON body leniently ([_parseLenientJson]),
///   then emit start → one full-args delta → end with a synthesized unique id
///   (mirroring `google.dart`'s id scheme). Unparseable or malformed bodies
///   are re-emitted as plain text. The fence consumes only the marker
///   characters themselves (not the newline terminating the closing fence
///   line), so text/fence decisions never depend on chunk boundaries and
///   fallback text is byte-faithful.
/// - An unclosed block at stream end is flushed as plain text.
/// - When at least one tool call was parsed, the terminal reason becomes
///   [StopReason.toolUse]; otherwise the inner reason passes through.
///   Usage, aborts, and errors pass through unchanged (content transformed).
///
/// Context transformation on the way in: [ToolResultMessage]s become
/// user-role `tool_result` fenced text, and historical [AssistantMessage]s
/// containing [ToolCall] blocks are re-serialized as `tool_call` fenced text
/// (round-trip fidelity). Thinking blocks are dropped from re-serialized
/// assistant messages (reasoning is streaming scratch; Google does the same
/// for cross-provider history).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../agent/agent_loop.dart' show StreamFunction;
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../json_parse.dart';
import '../model.dart';
import '../prompts/prompts.g.dart';
import '../providers/provider_common.dart';
import '../types.dart';

/// The fence tag opening a tool-call block: ```` ```tool_call ````.
const _openerMarker = '```tool_call';

/// Matches a complete opener, allowing trailing spaces/tabs and a CRLF.
final _openerPattern = RegExp(r'```tool_call[ \t]*\r?\n');

/// The fence close: ```` ``` ```` at line start.
const _closerMarker = '```';

/// The fence tag wrapping tool results fed back to the model.
const _resultMarker = '```tool_result';

// Counter for synthesizing unique tool call ids (mirrors google.dart's
// module-level `toolCallCounter`).
var _toolCallCounter = 0;

/// Which wire format the wrapper teaches the model and parses back.
///
/// Only one variant exists for now; the enum documents the extension point.
enum PromptToolFormat {
  /// Markdown-fenced ```` ```tool_call ```` blocks containing one JSON object
  /// with `name` and `arguments`.
  fencedJson,
}

/// Options for [promptToolStreamFunction].
final class PromptToolOptions {
  /// Creates prompt-tool options.
  const PromptToolOptions({
    this.maxBlockSize = 64 * 1024,
    this.injectWhenNoTools = false,
    this.format = PromptToolFormat.fencedJson,
  });

  /// Maximum buffered size in characters of one `tool_call` block body.
  /// Overflowing blocks are emitted as plain text and parsing resumes in
  /// text mode.
  final int maxBlockSize;

  /// Whether to inject the tool instructions even when [Context.tools] is
  /// empty. Default `false`: with no tools the wrapper is a byte-identical
  /// passthrough.
  final bool injectWhenNoTools;

  /// The wire format to inject and parse.
  final PromptToolFormat format;
}

/// Wraps [inner] with prompt-based tool calling.
///
/// When `context.tools` is non-empty (or
/// [PromptToolOptions.injectWhenNoTools] is set), the returned
/// [StreamFunction] appends the tool instructions to the system prompt,
/// re-serializes tool calls/results in the message history as fenced text,
/// and parses `tool_call` fenced blocks out of the inner stream's text into
/// the harness tool-call event contract. Otherwise the inner stream is
/// returned untouched (byte-identical passthrough).
///
/// The wrapper preserves the provider contract: it never throws and
/// terminates with exactly one [DoneEvent] or [ErrorEvent].
StreamFunction promptToolStreamFunction(
  StreamFunction inner, {
  PromptToolOptions? options,
}) {
  final opts = options ?? const PromptToolOptions();
  return (Model model, Context context, {CancelToken? cancelToken}) {
    final tools = context.tools ?? const <Tool>[];
    if (tools.isEmpty && !opts.injectWhenNoTools) {
      return inner(model, context, cancelToken: cancelToken);
    }

    final out = AssistantMessageEventStream();
    final parser = _PromptToolStreamParser(out, opts, model);

    final AssistantMessageEventStream innerStream;
    try {
      innerStream = inner(
        model,
        _transformContext(context, tools),
        cancelToken: cancelToken,
      );
    } catch (error) {
      // Defensive: the StreamFunction contract is never-throw.
      parser.fail(error);
      out.end();
      return out;
    }

    unawaited(() async {
      try {
        await for (final event in innerStream) {
          parser.handle(event);
        }
        parser.streamClosed();
      } catch (error) {
        // Defensive: inner streams report failures as ErrorEvents.
        parser.fail(error);
      } finally {
        out.end();
      }
    }());
    return out;
  };
}

/// Renders the tool-instruction section [promptToolStreamFunction] appends
/// to the system prompt when [tools] is non-empty (the
/// `prompts/tools/tool_calling.md` template with the numbered
/// name/description/schema list).
///
/// Exposed so hosts that size a context window (e.g. compaction thresholds
/// for small on-device models) can count the wrapper's bytes: the
/// instructions travel inside the system message and consume real window
/// tokens — for a full built-in tool set they dwarf the base system prompt.
String promptToolInstructions(List<Tool> tools) => _buildToolsSection(tools);

/// Appends the tool instructions to the system prompt and re-serializes
/// tool-shaped history messages as fenced text.
Context _transformContext(Context context, List<Tool> tools) {
  final section = _buildToolsSection(tools);
  final existing = context.systemPrompt;
  return Context(
    systemPrompt: existing == null || existing.trim().isEmpty
        ? section
        : '$existing\n\n$section',
    messages: [
      for (final message in context.messages) _transformMessage(message),
    ],
    tools: context.tools,
  );
}

/// Renders the tool instructions template with the numbered tool list.
String _buildToolsSection(List<Tool> tools) {
  final list = StringBuffer();
  for (var i = 0; i < tools.length; i++) {
    final tool = tools[i];
    list
      ..write(i + 1)
      ..write('. ')
      ..write(tool.name)
      ..write(': ')
      ..writeln(tool.description)
      ..write('   Parameters: ')
      ..writeln(jsonEncode(tool.parameters));
  }
  return toolCallingInstructionsPrompt.replaceAll(
    '{{tools}}',
    list.toString().trimRight(),
  );
}

/// Converts [message] for a prompt-based tool-calling conversation.
Message _transformMessage(Message message) {
  if (message is ToolResultMessage) {
    return UserMessage(
      content: _serializeToolResult(message),
      timestamp: message.timestamp,
    );
  }
  if (message is AssistantMessage) {
    if (!message.content.any((block) => block is ToolCall)) {
      return message;
    }
    final content = <ContentBlock>[];
    for (final block in message.content) {
      switch (block) {
        case TextContent():
          // Skip empty text blocks, mirroring the provider adapters.
          if (block.text.trim().isNotEmpty) {
            content.add(block);
          }
        case ToolCall():
          content.add(TextContent(text: _serializeToolCall(block)));
        case ThinkingContent() || ImageContent():
          // Reasoning is streaming scratch; images are invalid in assistant
          // messages. Drop both.
          break;
      }
    }
    return message.copyWith(content: content);
  }
  return message;
}

/// Re-serializes a historical [ToolCall] as a fenced `tool_call` block.
String _serializeToolCall(ToolCall call) {
  final json = jsonEncode({'name': call.name, 'arguments': call.arguments});
  return '$_openerMarker\n$json\n$_closerMarker';
}

/// Serializes a [ToolResultMessage] as user-role fenced `tool_result` text.
String _serializeToolResult(ToolResultMessage message) {
  final buffer = StringBuffer()
    ..writeln(_resultMarker)
    ..writeln('tool: ${message.toolName}');
  if (message.isError) {
    buffer.writeln('error: true');
  }
  buffer.writeln();
  for (final block in message.content) {
    if (block is TextContent) {
      buffer.writeln(block.text);
    } else if (block is ImageContent) {
      buffer.writeln('[image omitted: ${block.mimeType}]');
    }
  }
  buffer.write(_closerMarker);
  return buffer.toString();
}

/// Incremental parser mapping inner chat-stream events to the harness
/// tool-call event contract. See the library doc for the state machine.
final class _PromptToolStreamParser {
  _PromptToolStreamParser(this._out, this._options, this._model);

  final AssistantMessageEventStream _out;
  final PromptToolOptions _options;
  final Model _model;

  final _blocks = <StreamingBlock>[];
  TextStreamingBlock? _currentText;

  /// Last inner partial; the base for every emitted snapshot (usage,
  /// responseId, timestamps, and future fields pass through).
  AssistantMessage? _lastPartial;

  /// Whether a `tool_call` block body is currently being buffered.
  var _inToolBlock = false;

  /// Held-back text-state suffix that may still become an opener.
  final _heldText = StringBuffer();

  /// The accumulated body of the open `tool_call` block.
  final _blockBuffer = StringBuffer();

  /// The exact opener text consumed (re-emitted verbatim on fallback).
  var _consumedOpener = '';

  /// Whether at least one tool call has been parsed (or mirrored).
  var _sawToolCall = false;

  /// Whether a terminal event was already emitted.
  var _terminated = false;

  /// Builds the immutable partial carried by the next event.
  AssistantMessage _snapshot({bool finalize = false}) {
    final content = [
      for (final block in _blocks) block.toContentBlock(finalize: finalize),
    ];
    final base = _lastPartial;
    if (base == null) {
      return AssistantMessage(
        content: content,
        api: _model.api,
        provider: _model.provider,
        model: _model.id,
        usage: Usage.zero,
        stopReason: _sawToolCall ? StopReason.toolUse : StopReason.stop,
        timestamp: DateTime.now(),
      );
    }
    return base.copyWith(
      content: content,
      stopReason: _sawToolCall ? StopReason.toolUse : base.stopReason,
    );
  }

  /// Maps one inner event to zero or more emitted events.
  void handle(AssistantMessageEvent event) {
    if (_terminated) {
      return;
    }
    _lastPartial = event.partial;
    switch (event) {
      case StartEvent():
        _out.push(StartEvent(partial: _snapshot()));
      case TextStartEvent() || TextEndEvent():
        // Inner block boundaries are ignored; text blocks are re-derived
        // from the parsed stream.
        break;
      case TextDeltaEvent():
        _feed(event.delta);
      case ThinkingStartEvent():
        _closeText();
        _blocks.add(ThinkingStreamingBlock());
        _out.push(
          ThinkingStartEvent(
            contentIndex: _blocks.length - 1,
            partial: _snapshot(),
          ),
        );
      case ThinkingDeltaEvent():
        final block = _blocks.lastOrNull;
        if (block is ThinkingStreamingBlock) {
          block.thinking.write(event.delta);
          _out.push(
            ThinkingDeltaEvent(
              contentIndex: _blocks.length - 1,
              delta: event.delta,
              partial: _snapshot(),
            ),
          );
        }
      case ThinkingEndEvent():
        final block = _blocks.lastOrNull;
        if (block is ThinkingStreamingBlock) {
          pushBlockEndEvent(_out, _blocks, block, _snapshot);
        }
      case ToolCallStartEvent():
        // Mirror a native tool call (wrapping a function-calling stream
        // stays transparent).
        final toolCall = event.partial.content.length > event.contentIndex
            ? event.partial.content[event.contentIndex]
            : null;
        if (toolCall is ToolCall) {
          _closeText();
          _sawToolCall = true;
          _blocks.add(
            ToolCallStreamingBlock(id: toolCall.id, name: toolCall.name)
              ..thoughtSignature = toolCall.thoughtSignature,
          );
          _out.push(
            ToolCallStartEvent(
              contentIndex: _blocks.length - 1,
              partial: _snapshot(),
            ),
          );
        }
      case ToolCallDeltaEvent():
        final block = _blocks.lastOrNull;
        if (block is ToolCallStreamingBlock) {
          block.partialArgs.write(event.delta);
          _out.push(
            ToolCallDeltaEvent(
              contentIndex: _blocks.length - 1,
              delta: event.delta,
              partial: _snapshot(),
            ),
          );
        }
      case ToolCallEndEvent():
        final block = _blocks.lastOrNull;
        if (block is ToolCallStreamingBlock) {
          _sawToolCall = true;
          pushBlockEndEvent(_out, _blocks, block, _snapshot);
        }
      case DoneEvent():
        _flush();
        _terminated = true;
        final reason = _sawToolCall ? StopReason.toolUse : event.reason;
        _out.push(
          DoneEvent(
            reason: reason,
            message: event.message.copyWith(
              content: [
                for (final block in _blocks)
                  block.toContentBlock(finalize: true),
              ],
              stopReason: reason,
            ),
          ),
        );
      case ErrorEvent():
        _flush();
        _terminated = true;
        _out.push(
          ErrorEvent(
            reason: event.reason,
            error: event.error.copyWith(
              content: [
                for (final block in _blocks)
                  block.toContentBlock(finalize: true),
              ],
            ),
            retryAfter: event.retryAfter,
          ),
        );
    }
  }

  /// Converts a defensive failure (throwing inner stream, or a stream that
  /// closed without a terminal event) into the terminal [ErrorEvent].
  void fail(Object error) {
    if (_terminated) {
      return;
    }
    _flush();
    _terminated = true;
    _out.push(
      ErrorEvent(
        reason: StopReason.error,
        error: _snapshot(finalize: true).copyWith(
          stopReason: StopReason.error,
          errorMessage: formatProviderError(error),
        ),
      ),
    );
  }

  /// Handles the inner stream closing without a terminal event.
  void streamClosed() {
    if (!_terminated) {
      fail(StateError('Inner stream ended without a terminal event'));
    }
  }

  /// Feeds one text fragment through the two-state text/tool-block machine.
  void _feed(String delta) {
    var chunk = delta;
    while (true) {
      if (_inToolBlock) {
        _blockBuffer.write(chunk);
        final buffered = _blockBuffer.toString();
        final closerIndex = _findCloser(buffered);
        if (closerIndex == -1) {
          if (buffered.length > _options.maxBlockSize) {
            // Overflow: emit the block as plain text and resume text mode.
            _inToolBlock = false;
            _emitText('$_consumedOpener$buffered');
            _blockBuffer.clear();
          }
          return;
        }
        final body = buffered.substring(0, closerIndex);
        final rest = buffered.substring(closerIndex + _closerMarker.length);
        _blockBuffer.clear();
        _inToolBlock = false;
        _finishBlock(body);
        if (rest.isEmpty) {
          return;
        }
        chunk = rest;
        continue;
      }

      final buffer = '$_heldText$chunk';
      _heldText.clear();
      final match = _openerPattern.firstMatch(buffer);
      if (match == null) {
        // Hold back the longest suffix that may still grow into an opener.
        final held = _heldSuffixLength(buffer);
        _emitText(buffer.substring(0, buffer.length - held));
        _heldText.write(buffer.substring(buffer.length - held));
        return;
      }
      _emitText(buffer.substring(0, match.start));
      _closeText();
      _inToolBlock = true;
      _consumedOpener = match.group(0)!;
      chunk = buffer.substring(match.end);
      if (chunk.isEmpty) {
        return;
      }
    }
  }

  /// Parses a closed block body and emits the tool-call event triple, or
  /// re-emits the block as plain text when the body is not a valid call.
  void _finishBlock(String body) {
    final call = _parseToolCall(body);
    if (call == null) {
      _emitText('$_consumedOpener$body$_closerMarker');
      return;
    }
    final (:name, :arguments) = call;
    final argsJson = jsonEncode(arguments);
    final block = ToolCallStreamingBlock(id: _nextToolCallId(name), name: name)
      ..partialArgs.write(argsJson);
    _blocks.add(block);
    _sawToolCall = true;
    _out.push(
      ToolCallStartEvent(
        contentIndex: _blocks.length - 1,
        partial: _snapshot(),
      ),
    );
    _out.push(
      ToolCallDeltaEvent(
        contentIndex: _blocks.length - 1,
        delta: argsJson,
        partial: _snapshot(),
      ),
    );
    pushBlockEndEvent(_out, _blocks, block, _snapshot);
  }

  /// Flushes all buffered text (unclosed block, held opener suffix) and
  /// closes the open text block. Called before terminal events.
  void _flush() {
    if (_inToolBlock) {
      _inToolBlock = false;
      _emitText('$_consumedOpener$_blockBuffer');
      _blockBuffer.clear();
    }
    if (_heldText.isNotEmpty) {
      _emitText(_heldText.toString());
      _heldText.clear();
    }
    _closeText();
  }

  /// Emits [text] as a delta, lazily opening a text block first.
  void _emitText(String text) {
    if (text.isEmpty) {
      return;
    }
    var block = _currentText;
    if (block == null) {
      block = TextStreamingBlock();
      _currentText = block;
      _blocks.add(block);
      _out.push(
        TextStartEvent(contentIndex: _blocks.length - 1, partial: _snapshot()),
      );
    }
    block.text.write(text);
    _out.push(
      TextDeltaEvent(
        contentIndex: _blocks.length - 1,
        delta: text,
        partial: _snapshot(),
      ),
    );
  }

  /// Closes the open text block, if any.
  void _closeText() {
    final block = _currentText;
    if (block != null) {
      _currentText = null;
      pushBlockEndEvent(_out, _blocks, block, _snapshot);
    }
  }
}

/// Synthesizes a unique tool call id, mirroring google.dart's scheme.
String _nextToolCallId(String name) {
  return '${name}_${DateTime.now().millisecondsSinceEpoch}'
      '_${_toolCallCounter += 1}';
}

/// Finds the fence closer (```` ``` ```` at line start) in [buffer], or -1.
int _findCloser(String buffer) {
  var from = 0;
  while (true) {
    final index = buffer.indexOf(_closerMarker, from);
    if (index == -1) {
      return -1;
    }
    if (index == 0 || buffer[index - 1] == '\n') {
      return index;
    }
    from = index + 1;
  }
}

/// Length of the longest suffix of [text] that may still grow into a fence
/// opener: a strict prefix of the marker, or the full marker followed by an
/// incomplete terminator (spaces/tabs and at most one carriage return).
int _heldSuffixLength(String text) {
  final markerIndex = text.lastIndexOf(_openerMarker);
  if (markerIndex != -1) {
    final tail = text.substring(markerIndex + _openerMarker.length);
    if (RegExp(r'^[ \t]*\r?$').hasMatch(tail)) {
      return text.length - markerIndex;
    }
  }
  final maxLength = min(text.length, _openerMarker.length);
  for (var length = maxLength; length > 0; length--) {
    if (_openerMarker.startsWith(text.substring(text.length - length))) {
      return length;
    }
  }
  return 0;
}

/// Parses a block body into a tool call, or `null` when the body is not a
/// valid call (missing/blank `name`, non-map `arguments`, bad JSON).
({String name, Map<String, dynamic> arguments})? _parseToolCall(String body) {
  final decoded = _parseLenientJson(body);
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  final name = decoded['name'];
  if (name is! String || name.trim().isEmpty) {
    return null;
  }
  final rawArguments = decoded['arguments'];
  final Map<String, dynamic> arguments;
  if (rawArguments == null) {
    arguments = const <String, dynamic>{};
  } else if (rawArguments is Map<String, dynamic>) {
    arguments = rawArguments;
  } else {
    return null;
  }
  return (name: name.trim(), arguments: arguments);
}

/// Lenient JSON parse: strict first, then [repairJson], then common small-
/// model mistakes (trailing commas, single-quoted strings).
Object? _parseLenientJson(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final withoutTrailingCommas = trimmed.replaceAllMapped(
    RegExp(r',\s*([}\]])'),
    (match) => match[1]!,
  );
  return _tryDecode(trimmed) ??
      _tryDecode(withoutTrailingCommas) ??
      _tryDecode(_singleToDoubleQuotes(withoutTrailingCommas));
}

/// Strict parse with one [repairJson] retry (raw control characters, bad
/// escapes inside strings), or `null`.
Object? _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    try {
      return jsonDecode(repairJson(text));
    } on FormatException {
      return null;
    }
  }
}

/// Last-resort recovery for single-quoted JSON: naive quote swap. Strings
/// containing apostrophes simply fail to parse and fall back to text.
String _singleToDoubleQuotes(String text) => text.replaceAll("'", '"');
