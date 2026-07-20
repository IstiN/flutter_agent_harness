/// A minimal LSP-framed echo server, spawned as a child process by
/// `io_lsp_transport_test.dart`. Not a test itself.
///
/// Protocol: answers `initialize` with canned capabilities, echoes every
/// other request as `{echo: method, params: params}`, answers `shutdown`
/// with null, and exits 0 on the `exit` notification.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

void main() {
  final framer = LspMessageFramer();
  stdin.listen((chunk) {
    framer.push(chunk);
    for (final text in framer.drain()) {
      final message = jsonDecode(text);
      if (message is! Map<String, dynamic>) continue;
      final method = message['method'];
      final id = message['id'];
      if (method == 'exit') {
        exit(0);
      }
      if (method is String && id != null) {
        final Object? result = switch (method) {
          'initialize' => {
            'capabilities': {'textDocumentSync': 1},
          },
          'shutdown' => null,
          _ => {'echo': method, 'params': message['params']},
        };
        final response = jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        });
        stdout.add(LspMessageFramer.encode(response));
      }
    }
  });
}
