/// Server-Sent Events (SSE) line decoder.
///
/// Ported from the hand-rolled decoder in pi-mono
/// `packages/ai/src/api/anthropic-messages.ts` (`iterateSseMessages`,
/// `decodeSseLine`, `flushSseEvent`, `consumeLine`, `nextLineBreakIndex`).
/// Kept mechanically close to the original so future pi fixes port trivially.
///
/// Unlike pi — which decodes bytes with `TextDecoder` inside the iterator —
/// this decoder consumes a `Stream<String>` of arbitrarily-split text chunks.
/// Byte streams are decoded upstream, e.g.:
///
/// ```dart
/// final events = byteStream
///     .transform(utf8.decoder)
///     .transform(const SseDecoder());
/// ```
library;

import 'dart:async';

/// A parsed Server-Sent Event.
///
/// Ported from pi's `ServerSentEvent`.
final class ServerSentEvent {
  ServerSentEvent({required this.event, required this.data, required this.raw});

  /// The `event:` field value, or `null` when the event had none.
  final String? event;

  /// The `data:` field values joined with `\n` (multi-line data per the SSE
  /// spec).
  final String data;

  /// The raw lines that made up this event, for diagnostics.
  final List<String> raw;
}

final class _SseDecoderState {
  String? event;
  final data = <String>[];
  final raw = <String>[];
}

ServerSentEvent? _flushSseEvent(_SseDecoderState state) {
  if (state.event == null && state.data.isEmpty) {
    return null;
  }

  final event = ServerSentEvent(
    event: state.event,
    data: state.data.join('\n'),
    raw: List.of(state.raw),
  );
  state.event = null;
  state.data.clear();
  state.raw.clear();
  return event;
}

ServerSentEvent? _decodeSseLine(String line, _SseDecoderState state) {
  if (line.isEmpty) {
    return _flushSseEvent(state);
  }

  state.raw.add(line);
  if (line.startsWith(':')) {
    // Comment line (also used for heartbeats).
    return null;
  }

  final delimiterIndex = line.indexOf(':');
  final fieldName = delimiterIndex == -1
      ? line
      : line.substring(0, delimiterIndex);
  var value = delimiterIndex == -1 ? '' : line.substring(delimiterIndex + 1);
  if (value.startsWith(' ')) {
    value = value.substring(1);
  }

  if (fieldName == 'event') {
    state.event = value;
  } else if (fieldName == 'data') {
    state.data.add(value);
  }
  // Other fields (id, retry, field-less lines, ...) are ignored, per the SSE
  // spec and pi's behavior.

  return null;
}

int _nextLineBreakIndex(String text) {
  final carriageReturnIndex = text.indexOf('\r');
  final newlineIndex = text.indexOf('\n');
  if (carriageReturnIndex == -1) {
    return newlineIndex;
  }
  if (newlineIndex == -1) {
    return carriageReturnIndex;
  }
  return carriageReturnIndex < newlineIndex
      ? carriageReturnIndex
      : newlineIndex;
}

({String line, String rest})? _consumeLine(String text) {
  final lineBreakIndex = _nextLineBreakIndex(text);
  if (lineBreakIndex == -1) {
    return null;
  }

  var nextIndex = lineBreakIndex + 1;
  if (text[lineBreakIndex] == '\r' &&
      nextIndex < text.length &&
      text[nextIndex] == '\n') {
    nextIndex += 1;
  }

  return (
    line: text.substring(0, lineBreakIndex),
    rest: text.substring(nextIndex),
  );
}

/// Decodes a stream of text chunks into [ServerSentEvent]s.
///
/// Handles LF, CRLF, and lone-CR line endings, events split across chunks,
/// comment (`:`) lines, and multi-line `data:` fields. A trailing event not
/// terminated by a blank line is flushed when the input stream closes —
/// matching pi's behavior.
class SseDecoder extends StreamTransformerBase<String, ServerSentEvent> {
  const SseDecoder();

  @override
  Stream<ServerSentEvent> bind(Stream<String> stream) async* {
    final state = _SseDecoderState();
    var buffer = '';

    await for (final chunk in stream) {
      buffer += chunk;
      var consumed = _consumeLine(buffer);
      while (consumed != null) {
        buffer = consumed.rest;
        final event = _decodeSseLine(consumed.line, state);
        if (event != null) {
          yield event;
        }
        consumed = _consumeLine(buffer);
      }
    }

    // Flush whatever the final chunk left behind.
    var consumed = _consumeLine(buffer);
    while (consumed != null) {
      buffer = consumed.rest;
      final event = _decodeSseLine(consumed.line, state);
      if (event != null) {
        yield event;
      }
      consumed = _consumeLine(buffer);
    }

    if (buffer.isNotEmpty) {
      final event = _decodeSseLine(buffer, state);
      if (event != null) {
        yield event;
      }
    }

    final trailingEvent = _flushSseEvent(state);
    if (trailingEvent != null) {
      yield trailingEvent;
    }
  }
}
