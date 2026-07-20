/// The `lsp` tool and its supporting LSP client stack (a reduced port of
/// oh-my-pi `packages/coding-agent/src/lsp/`): a pure-Dart JSON-RPC/LSP
/// protocol client, server configuration, workspace-edit application, and
/// the session lifecycle manager.
///
/// The `dart:io` process transport is NOT here — it lives in
/// `lib/src/lsp/io_lsp_transport.dart` and is exported only from
/// `lib/io.dart`, keeping this subtree web-safe.
library;

export 'lsp_client.dart';
export 'lsp_config.dart';
export 'lsp_edits.dart';
export 'lsp_framing.dart';
export 'lsp_manager.dart';
export 'lsp_tool.dart';
export 'lsp_transport.dart';
export 'lsp_types.dart';
