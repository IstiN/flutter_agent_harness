/// MCP (Model Context Protocol) support: external tool servers plugged into
/// the agent via the `mcp:` section of `~/.fah/config.yaml`.
///
/// Servers are stdio processes (`command`/`args`/`env`, newline-delimited
/// JSON-RPC) or remote HTTP endpoints (`url`, streamable-http or legacy
/// sse). The manager connects lazily in the background and registers each
/// advertised tool as `mcp__<server>__<tool>`; reconnect with capped
/// backoff follows the `LspClientManager` policy. Resources and prompts are
/// out of scope.
library;

export 'mcp_client.dart';
export 'mcp_config.dart';
export 'mcp_framing.dart';
export 'mcp_http_transport.dart';
export 'mcp_manager.dart';
export 'mcp_tool.dart';
export 'mcp_transport.dart';
