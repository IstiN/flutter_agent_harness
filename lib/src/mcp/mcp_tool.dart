/// The MCP tool wrapper: each tool advertised by a connected MCP server
/// becomes one [AgentTool] named `mcp__<server>__<tool>` (namespaced, so
/// cross-server collisions cannot silently shadow each other), with the
/// description prefixed by its origin and the `inputSchema` passed through
/// verbatim. Calls route through the [McpToolCaller] the manager provides.
///
/// Result conversion maps MCP content blocks onto our [ContentBlock] types:
/// text as-is, images as [ImageContent], embedded resources and resource
/// links as readable text placeholders. Text output shares a 100k
/// character budget ([mcpResultTextBudget]); overshoot is cut with a
/// truncation note. A result with `isError: true` throws, so the agent loop
/// records an error tool result (pi semantics).
library;

import 'dart:convert';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../types.dart';
import 'mcp_client.dart';

/// Shared character budget for the TEXT of one MCP tool result.
const mcpResultTextBudget = 100000;

/// Calls [tool] on [server] with [arguments], returning the raw MCP result
/// map. Provided by the manager so the wrapper never holds a client.
typedef McpToolCaller =
    Future<Map<String, dynamic>> Function(
      String server,
      String tool,
      Map<String, dynamic> arguments,
    );

/// The registered name of [tool] from [server]: `mcp__<server>__<tool>`
/// with provider-hostile characters flattened to `_` and the result clamped
/// to 64 characters (the common provider tool-name limit).
String mcpToolName(String server, String tool) {
  String sanitize(String value) {
    final cleaned = value.replaceAll(RegExp('[^a-zA-Z0-9_-]+'), '_');
    return cleaned.isEmpty ? 'x' : cleaned;
  }

  final name = 'mcp__${sanitize(server)}__${sanitize(tool)}';
  return name.length <= 64 ? name : name.substring(0, 64);
}

/// Builds the [AgentTool] for one advertised MCP tool.
AgentTool mcpAgentTool({
  required String server,
  required McpToolInfo tool,
  required McpToolCaller caller,
}) {
  final description = StringBuffer("MCP tool from server '$server'.");
  final toolDescription = tool.description;
  if (toolDescription != null && toolDescription.isNotEmpty) {
    description.write(' $toolDescription');
  }
  return AgentTool(
    name: mcpToolName(server, tool.name),
    label: 'mcp:$server/${tool.name}',
    // MCP tools run arbitrary server-side actions: the exec tier keeps the
    // approval gate's safest default for them.
    tier: ApprovalTier.exec,
    description: description.toString(),
    parameters:
        tool.inputSchema ??
        const {'type': 'object', 'properties': <String, dynamic>{}},
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final result = await caller(server, tool.name, arguments);
      cancelToken?.throwIfCancelled();
      return mcpResultToToolResult(result);
    },
  );
}

/// Converts a raw `tools/call` result map into a [ToolExecutionResult].
/// Throws [StateError] when the result carries `isError: true` (the loop
/// turns the throw into an error tool result).
ToolExecutionResult mcpResultToToolResult(Map<String, dynamic> result) {
  final content = mcpContentBlocks(result['content']);
  if (result['isError'] == true) {
    final message = content
        .whereType<TextContent>()
        .map((block) => block.text)
        .join('\n');
    throw StateError(message.isEmpty ? 'MCP tool reported an error' : message);
  }
  if (content.isEmpty) {
    final structured = result['structuredContent'];
    if (structured != null) {
      return ToolExecutionResult.text(_fitTextBudget(jsonEncode(structured)));
    }
    return ToolExecutionResult.text('[MCP tool returned no content]');
  }
  return ToolExecutionResult(content: _fitBudget(content));
}

/// Maps MCP content blocks onto [ContentBlock]s: text as-is, images as
/// [ImageContent], everything else as a readable text placeholder.
List<ContentBlock> mcpContentBlocks(Object? content) {
  if (content is! List) return const [];
  return [
    for (final entry in content)
      if (entry is Map<String, dynamic>) _mcpContentBlock(entry),
  ];
}

ContentBlock _mcpContentBlock(Map<String, dynamic> entry) {
  return switch (entry['type']) {
    'text' => _mcpTextBlock(entry),
    'image' => _mcpImageBlock(entry),
    'resource' => TextContent(text: _resourceText(entry['resource'])),
    'resource_link' => TextContent(text: _resourceLinkText(entry)),
    'audio' => TextContent(
      text: '[Audio content omitted (${entry['mimeType'] ?? 'audio'})]',
    ),
    _ => TextContent(text: '[Unsupported MCP content block: ${entry['type']}]'),
  };
}

ContentBlock _mcpTextBlock(Map<String, dynamic> entry) {
  final text = entry['text'];
  return TextContent(text: text is String ? text : '[Unreadable text block]');
}

ContentBlock _mcpImageBlock(Map<String, dynamic> entry) {
  final data = entry['data'];
  final mimeType = entry['mimeType'];
  if (data is String && mimeType is String) {
    return ImageContent(data: data, mimeType: mimeType);
  }
  return const TextContent(text: '[Unreadable image block]');
}

String _resourceText(Object? resource) {
  if (resource is! Map<String, dynamic>) {
    return '[Embedded resource: unreadable]';
  }
  final uri = resource['uri'] ?? 'unknown';
  final text = resource['text'];
  if (text is String) return '[Resource: $uri]\n$text';
  final blob = resource['blob'];
  final size = blob is String ? blob.length : 0;
  return '[Embedded resource: $uri '
      '(${resource['mimeType'] ?? 'application/octet-stream'}, '
      '$size base64 chars — binary content not shown)]';
}

String _resourceLinkText(Map<String, dynamic> entry) {
  final uri = entry['uri'] ?? 'unknown';
  final name = entry['name'];
  final description = entry['description'];
  final buffer = StringBuffer(
    '[Resource link: ${name is String && name.isNotEmpty ? name : uri}]',
  );
  if (name is String && name.isNotEmpty) buffer.write('\n$uri');
  if (description is String && description.isNotEmpty) {
    buffer.write('\n$description');
  }
  return buffer.toString();
}

/// Applies the shared text budget across [blocks] (images don't count).
List<ContentBlock> _fitBudget(List<ContentBlock> blocks) {
  var remaining = mcpResultTextBudget;
  final out = <ContentBlock>[];
  var truncated = false;
  for (final block in blocks) {
    if (block is! TextContent) {
      out.add(block);
      continue;
    }
    if (truncated) continue;
    if (block.text.length <= remaining) {
      remaining -= block.text.length;
      out.add(block);
    } else {
      out.add(TextContent(text: block.text.substring(0, remaining)));
      truncated = true;
    }
  }
  if (truncated) {
    out.add(
      TextContent(
        text:
            '[... truncated: MCP result exceeded the '
            '$mcpResultTextBudget-character budget]',
      ),
    );
  }
  return out;
}

String _fitTextBudget(String text) {
  if (text.length <= mcpResultTextBudget) return text;
  return '${text.substring(0, mcpResultTextBudget)}\n'
      '[... truncated: MCP result exceeded the '
      '$mcpResultTextBudget-character budget]';
}
