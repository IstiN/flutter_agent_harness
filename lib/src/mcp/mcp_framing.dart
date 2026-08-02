/// Incremental line decoder for the newline-delimited JSON stream spoken by
/// MCP stdio servers.
///
/// MCP's stdio transport frames each JSON-RPC message as a single line of
/// UTF-8 JSON terminated by `\n` (embedded newlines are not allowed) — unlike
/// LSP's `Content-Length` headers. Feed raw chunks with [push], pull every
/// complete line with [drain]. Blank lines are skipped as non-protocol
/// noise (wrapper scripts sometimes print them).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Incremental newline framer. One framer per server connection.
final class McpLineFramer {
  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Appends a freshly read chunk to the pending buffer.
  void push(List<int> chunk) {
    if (chunk.isEmpty) return;
    _pending.add(chunk);
  }

  /// Returns the text of every complete line currently buffered (without
  /// the terminating newline). Blank lines are dropped.
  List<String> drain() {
    final bytes = _pending.takeBytes();
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != 10) continue;
      // Tolerate CRLF emitters by stripping a trailing \r.
      final end = i > start && bytes[i - 1] == 13 ? i - 1 : i;
      if (end > start) {
        lines.add(utf8.decode(Uint8List.sublistView(bytes, start, end)));
      }
      start = i + 1;
    }
    if (start < bytes.length) {
      _pending.add(Uint8List.sublistView(bytes, start));
    }
    return lines;
  }

  /// Encodes [jsonText] as one framed stdio message ready for the wire.
  static Uint8List encode(String jsonText) {
    final body = utf8.encode(jsonText);
    final out = Uint8List(body.length + 1);
    out.setAll(0, body);
    out[body.length] = 10;
    return out;
  }
}
