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
    // The SSE spec requires stripping a single UTF-8 BOM at the very start
    // of the stream. Upstream byte decoding (utf8.decoder) always delivers
    // the BOM as one leading U+FEFF character, possibly after empty chunks.
    var atStreamStart = true;

    await for (final chunk in stream) {
      buffer += chunk;
      if (atStreamStart && buffer.isNotEmpty) {
        atStreamStart = false;
        if (buffer.startsWith('\uFEFF')) buffer = buffer.substring(1);
      }
      final (rest, events) = _drainSseLines(buffer, state);
      buffer = rest;
      for (final event in events) {
        yield event;
      }
    }

    // Flush whatever the final chunk left behind.
    final (rest, events) = _drainSseLines(buffer, state);
    buffer = rest;
    for (final event in events) {
      yield event;
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

  /// Decodes every complete line in [buffer], returning the unconsumed rest
  /// and the parsed events.
  (String, List<ServerSentEvent>) _drainSseLines(
    String buffer,
    _SseDecoderState state,
  ) {
    final events = <ServerSentEvent>[];
    final len = buffer.length;
    var start = 0;
    while (start < len) {
      final lf = buffer.indexOf('\n', start);
      final cr = buffer.indexOf('\r', start);
      int lineBreakIndex;
      if (cr == -1) {
        lineBreakIndex = lf;
      } else if (lf == -1) {
        lineBreakIndex = cr;
      } else {
        lineBreakIndex = cr < lf ? cr : lf;
      }
      if (lineBreakIndex == -1) break;
      final line = buffer.substring(start, lineBreakIndex);
      start = lineBreakIndex + 1;
      if (buffer.codeUnitAt(lineBreakIndex) == 0x0d &&
          start < len &&
          buffer.codeUnitAt(start) == 0x0a) {
        start += 1;
      }
      final event = _decodeSseLine(line, state);
      if (event != null) {
        events.add(event);
      }
    }
    final rest = start == 0
        ? buffer
        : (start >= len ? '' : buffer.substring(start));
    return (rest, events);
  }
}
