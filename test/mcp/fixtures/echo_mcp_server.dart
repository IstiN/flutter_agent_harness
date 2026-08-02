/// A minimal real MCP stdio server for the io transport test: reads
/// newline-delimited JSON-RPC from stdin and answers `initialize`,
/// `tools/list` (one `echo` tool), and `tools/call`.
library;

import 'dart:convert';
import 'dart:io';

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.trim().isEmpty) return;
    final message = jsonDecode(line) as Map<String, dynamic>;
    final id = message['id'];
    final method = message['method'];
    if (id == null || method is! String) return; // notifications
    final Object? result = switch (method) {
      'initialize' => {
        'protocolVersion': '2025-06-18',
        'capabilities': const <String, dynamic>{},
        'serverInfo': {'name': 'echo-mcp', 'version': '0.0.1'},
      },
      'tools/list' => {
        'tools': [
          {
            'name': 'echo',
            'description': 'Echoes the text argument.',
            'inputSchema': {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
              },
            },
          },
        ],
      },
      'tools/call' => {
        'content': [
          {
            'type': 'text',
            'text': 'echo:${(message['params'] as Map)['arguments']?['text']}',
          },
        ],
      },
      _ => null,
    };
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  });
}
