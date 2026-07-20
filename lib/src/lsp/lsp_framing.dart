/// Incremental `Content-Length` frame decoder for the JSON-RPC byte stream
/// spoken by LSP stdio servers.
///
/// Ported from oh-my-pi `packages/coding-agent/src/jsonrpc/
/// message-framing.ts` (`MessageFramer`): each message is a
/// `Content-Length: <n>\r\n\r\n` header block followed by `<n>` bytes of
/// UTF-8 JSON. Feed raw chunks with [push], pull every complete message with
/// [drain]. A header block without a `Content-Length` is non-protocol noise
/// (e.g. a wrapper script printing to stdout): [drain] reports it through
/// `onResync` and drops past the bogus terminator instead of stalling on the
/// same junk header forever.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Incremental Content-Length framer. Not thread-safe (Dart is single
/// threaded); one framer per server connection.
final class LspMessageFramer {
  /// Creates a framer, optionally seeded with the unparsed [seed] remainder
  /// left by a previous reader so a restarted reader resumes mid-message.
  LspMessageFramer([Uint8List? seed]) {
    if (seed != null && seed.isNotEmpty) {
      _pendingChunks.add(seed);
      _pendingLen = seed.length;
    }
  }

  final List<Uint8List> _pendingChunks = [];
  int _pendingLen = 0;

  /// Appends a freshly read chunk to the pending buffer.
  void push(List<int> chunk) {
    if (chunk.isEmpty) return;
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    _pendingChunks.add(bytes);
    _pendingLen += bytes.length;
  }

  /// The unparsed remainder, to persist when the reader stops.
  Uint8List remainder() {
    if (_pendingChunks.isEmpty) return Uint8List(0);
    if (_pendingChunks.length == 1) return _pendingChunks.first;
    final out = Uint8List(_pendingLen);
    var offset = 0;
    for (final chunk in _pendingChunks) {
      out.setAll(offset, chunk);
      offset += chunk.length;
    }
    return out;
  }

  /// Removes the first [count] buffered bytes.
  void _dropFront(int count) {
    var removed = 0;
    while (_pendingChunks.isNotEmpty) {
      final head = _pendingChunks.first;
      if (removed + head.length <= count) {
        removed += head.length;
        _pendingChunks.removeAt(0);
      } else {
        _pendingChunks[0] = Uint8List.sublistView(head, count - removed);
        break;
      }
    }
    _pendingLen -= count;
  }

  /// Copies the byte range [from, to) out of the pending chunks.
  Uint8List _copyRange(int from, int to) {
    final out = Uint8List(to - from);
    var global = 0;
    var written = 0;
    for (final chunk in _pendingChunks) {
      final chunkEnd = global + chunk.length;
      if (chunkEnd > from && global < to) {
        final start = (from > global ? from : global) - global;
        final end = (to < chunkEnd ? to : chunkEnd) - global;
        out.setRange(written, written + (end - start), chunk, start);
        written += end - start;
      }
      global = chunkEnd;
      if (global >= to) break;
    }
    return out;
  }

  /// Locates the `\r\n\r\n` header terminator across the pending chunks.
  /// Returns the absolute byte index of the first `\r`, or -1 when absent.
  int _findHeaderEnd() {
    var global = 0;
    var b0 = -1, b1 = -1, b2 = -1;
    for (final chunk in _pendingChunks) {
      for (var i = 0; i < chunk.length; i++) {
        final b3 = chunk[i];
        if (b0 == 13 && b1 == 10 && b2 == 13 && b3 == 10) {
          return global - 3;
        }
        b0 = b1;
        b1 = b2;
        b2 = b3;
        global++;
      }
    }
    return -1;
  }

  static final RegExp _contentLengthPattern = RegExp(
    r'Content-Length: (\d+)',
    caseSensitive: false,
  );

  /// Returns the JSON text of every complete message currently buffered.
  ///
  /// A header block without a `Content-Length` is reported through
  /// [onResync] and skipped (resync); messages split across chunks simply
  /// wait for more bytes.
  List<String> drain({void Function(String headerText)? onResync}) {
    final messages = <String>[];
    while (true) {
      final headerEnd = _findHeaderEnd();
      if (headerEnd == -1) break;

      final headerText = utf8.decode(_copyRange(0, headerEnd));
      final match = _contentLengthPattern.firstMatch(headerText);
      if (match == null) {
        onResync?.call(headerText);
        _dropFront(headerEnd + 4);
        continue;
      }

      final contentLength = int.parse(match.group(1)!);
      final messageStart = headerEnd + 4; // skip \r\n\r\n
      final messageEnd = messageStart + contentLength;
      if (_pendingLen < messageEnd) break;

      messages.add(utf8.decode(_copyRange(messageStart, messageEnd)));
      _dropFront(messageEnd);
    }
    return messages;
  }

  /// Encodes [jsonText] as a framed LSP message ready for the wire.
  static Uint8List encode(String jsonText) {
    final body = utf8.encode(jsonText);
    final header = utf8.encode('Content-Length: ${body.length}\r\n\r\n');
    final out = Uint8List(header.length + body.length);
    out.setAll(0, header);
    out.setAll(header.length, body);
    return out;
  }
}
