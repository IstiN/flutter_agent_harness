/// Session-scoped subagent output addressing: unique id allocation, the
/// in-memory output store, and the `agent://` URL resolver.
///
/// Ported (reduced) from oh-my-pi:
///
/// - `packages/coding-agent/src/task/output-manager.ts` — [AgentOutputManager]
///   keeps every subagent output id unique within a session: a requested name
///   is used verbatim the first time, repeats get `-2`/`-3` suffixes, and a
///   parent prefix nests ids (`Parent.Child`). omp additionally seeds from
///   on-disk artifacts; the v1 store is in-memory (pure-Dart `lib/` cannot
///   touch the filesystem — a durable artifacts dir is a follow-up).
/// - `packages/coding-agent/src/internal-urls/agent-protocol.ts` —
///   [resolveAgentUrl] ports the resolution forms: `agent://<id>` (full
///   output), `agent://<id>/<child>` (nested output via dot-qualified ids),
///   `agent://<id>/<path>` (JSON extraction; dot-separated keys and numeric
///   array indices), and `agent://<id>?q=<query>` (always extraction). omp's
///   jq-style query grammar is reduced to the dot-path subset.
library;

// The public named parameter maps to a private field; an initializing formal
// would make the parameter name private and unusable outside this library.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'task_types.dart';

/// Manages agent output id allocation to ensure uniqueness (port of omp's
/// `AgentOutputManager`).
final class AgentOutputManager {
  /// Creates a manager. [parentPrefix] nests every allocated id under it
  /// (`Parent.Child`) so hierarchical outputs stay grouped.
  AgentOutputManager({String? parentPrefix}) : _parentPrefix = parentPrefix;

  /// Final ids already handed out, relative to this manager's scope.
  final _taken = <String>{};
  final String? _parentPrefix;

  /// Allocates a unique id: [requested] verbatim the first time, then
  /// `requested-2`, `requested-3`, … (omp's `#allocateUnique`).
  String allocate(String requested) {
    var candidate = requested;
    for (var n = 2; _taken.contains(candidate); n++) {
      candidate = '$requested-$n';
    }
    _taken.add(candidate);
    return _parentPrefix == null ? candidate : '$_parentPrefix.$candidate';
  }
}

/// Session-scoped store of subagent outputs addressable via `agent://`.
///
/// One store is shared by every `task` tool instance of a session (pass it
/// through `TaskToolConfig.outputs`), so ids never collide across calls and
/// every finished spawn stays addressable.
final class AgentOutputStore {
  /// Creates a store with its own id allocator ([ids] injects a shared or
  /// prefixed one — children allocate their own children dot-qualified).
  AgentOutputStore({AgentOutputManager? ids})
    : ids = ids ?? AgentOutputManager();

  /// The id allocator backing [allocateId].
  final AgentOutputManager ids;

  final _outputs = <String, String>{};

  /// Allocates a unique output id for [requestedBase].
  String allocateId(String requestedBase) => ids.allocate(requestedBase);

  /// Records [content] under [id] (later writes replace earlier ones — a
  /// schema fix retry updates its item's output).
  void put(String id, String content) => _outputs[id] = content;

  /// The stored output for [id]; `null` when unknown.
  String? get(String id) => _outputs[id];

  /// Whether [id] has stored output.
  bool contains(String id) => _outputs.containsKey(id);

  /// All stored ids, in insertion order.
  List<String> get availableIds => List.unmodifiable(_outputs.keys);
}

/// Thrown when an `agent://` URL cannot be resolved (port of omp's
/// model-visible protocol errors).
final class AgentUrlException implements Exception {
  /// Creates an [AgentUrlException].
  const AgentUrlException(this.message);

  /// The model-facing error message.
  final String message;

  @override
  String toString() => message;
}

/// A resolved `agent://` resource.
final class AgentUrlResolution {
  /// Creates an [AgentUrlResolution].
  const AgentUrlResolution({
    required this.id,
    required this.content,
    required this.contentType,
    this.notes = const [],
  });

  /// The id the URL resolved to (a nested id when the URL hopped the
  /// hierarchy).
  final String id;

  /// The resolved content (pretty-printed JSON after extraction).
  final String content;

  /// `text/markdown` for raw outputs, `application/json` after extraction.
  final String contentType;

  /// Resolution notes (e.g. the applied extraction query).
  final List<String> notes;
}

/// Resolves an `agent://` URL against [store] (port of omp's
/// `AgentProtocolHandler.resolve`, reduced to the dot-path query subset).
///
/// Throws [AgentUrlException] on malformed URLs, unknown ids, conflicting
/// extraction syntax, or non-JSON content named for extraction.
AgentUrlResolution resolveAgentUrl(String url, AgentOutputStore store) {
  final parsed = _splitAgentUrl(url);
  final hasPathExtraction = parsed.urlPath.isNotEmpty && parsed.urlPath != '/';
  if (hasPathExtraction && parsed.query != null) {
    throw AgentUrlException(
      '$agentUrlScheme:// URL cannot combine path extraction with ?q=',
    );
  }

  final hop = _resolveUrlPath(parsed.outputId, parsed.urlPath);
  final resolved = _resolveRawContent(store, parsed.outputId, hop.nestedId);
  final resolvedNested = hop.nestedId != null && resolved.id == hop.nestedId;
  final extract =
      parsed.query != null || (hasPathExtraction && !resolvedNested);
  if (!extract) {
    return AgentUrlResolution(
      id: resolved.id,
      content: resolved.content,
      contentType: 'text/markdown',
    );
  }
  return _extractJsonContent(resolved, parsed.query, hop.segments.join('.'));
}

/// Decodes the slash [urlPath] into dot-path [segments] and the
/// dot-qualified nested output id they name. A subagent allocates its own
/// children as dot-qualified ids (`Parent.Child`), so the slash path form is
/// first tried as a hierarchy separator. Only when no such nested output
/// exists does the path fall back to dot-path JSON extraction (omp
/// semantics); a segment containing a dot is never a hierarchy hop.
({String? nestedId, List<String> segments}) _resolveUrlPath(
  String outputId,
  String urlPath,
) {
  final segments = [
    for (final raw in urlPath.split('/'))
      if (raw.isNotEmpty) Uri.decodeComponent(raw),
  ];
  final nestedId =
      segments.isNotEmpty && segments.every((s) => !s.contains('.'))
      ? [outputId, ...segments].join('.')
      : null;
  return (nestedId: nestedId, segments: segments);
}

/// Splits an `agent://` [url] into its output id, slash path, and `?q=`
/// query (normalized to `null` when absent or empty), enforcing the scheme
/// and output-id rules of the protocol.
({String outputId, String urlPath, String? query}) _splitAgentUrl(String url) {
  const prefix = '$agentUrlScheme://';
  if (!url.startsWith(prefix)) {
    throw AgentUrlException('Not an $agentUrlScheme:// URL: $url');
  }
  final rest = url.substring(prefix.length);
  final queryIndex = rest.indexOf('?');
  final pathPart = queryIndex >= 0 ? rest.substring(0, queryIndex) : rest;
  final queryPart = queryIndex >= 0 ? rest.substring(queryIndex + 1) : null;

  final path = _splitPathPart(pathPart);
  return (
    outputId: path.outputId,
    urlPath: path.urlPath,
    query: _parseQueryParam(queryPart),
  );
}

/// Splits [pathPart] at the first slash into the output id and the
/// remaining slash path; the output id must not be empty.
({String outputId, String urlPath}) _splitPathPart(String pathPart) {
  final slashIndex = pathPart.indexOf('/');
  final outputId = slashIndex >= 0
      ? pathPart.substring(0, slashIndex)
      : pathPart;
  final urlPath = slashIndex >= 0 ? pathPart.substring(slashIndex) : '';
  if (outputId.isEmpty) {
    throw AgentUrlException(
      '$agentUrlScheme:// URL requires an output ID: $agentUrlScheme://<id>',
    );
  }
  return (outputId: outputId, urlPath: urlPath);
}

/// The `q` parameter of [queryPart], normalized to `null` when absent or
/// empty.
String? _parseQueryParam(String? queryPart) {
  String? queryParam;
  if (queryPart != null && queryPart.isNotEmpty) {
    queryParam = Uri.splitQueryString(queryPart)['q'];
  }
  if (queryParam != null && queryParam.isEmpty) queryParam = null;
  return queryParam;
}

/// Fetches the raw stored content for [outputId], preferring the
/// dot-qualified [nestedId] when the URL hopped the output hierarchy and
/// such a nested output exists (omp semantics).
({String id, String content}) _resolveRawContent(
  AgentOutputStore store,
  String outputId,
  String? nestedId,
) {
  if (nestedId != null && store.contains(nestedId)) {
    return (id: nestedId, content: store.get(nestedId)!);
  }
  final content = store.get(outputId);
  if (content == null) {
    final available = store.availableIds;
    throw AgentUrlException(
      'Not found: ${nestedId ?? outputId}\n'
      'Available: ${available.isEmpty ? 'none' : available.join(', ')}',
    );
  }
  return (id: outputId, content: content);
}

/// Decodes [resolved] content as JSON and extracts [queryParam] (or
/// [pathQuery] when no explicit `?q=` was given) from it; an empty query
/// re-prints the whole document.
AgentUrlResolution _extractJsonContent(
  ({String id, String content}) resolved,
  String? queryParam,
  String pathQuery,
) {
  final Object? jsonValue;
  try {
    jsonValue = jsonDecode(resolved.content);
  } on FormatException catch (error) {
    throw AgentUrlException(
      'Output ${resolved.id} is not valid JSON: ${error.message}',
    );
  }

  final query = queryParam ?? pathQuery;
  if (query.isEmpty) {
    return AgentUrlResolution(
      id: resolved.id,
      content: const JsonEncoder.withIndent('  ').convert(jsonValue),
      contentType: 'application/json',
    );
  }
  final extracted = _walkJsonPath(jsonValue, query, resolved.id);
  String content;
  try {
    content = const JsonEncoder.withIndent('  ').convert(extracted);
  } on JsonUnsupportedObjectError {
    content = '$extracted';
  }
  return AgentUrlResolution(
    id: resolved.id,
    content: content,
    contentType: 'application/json',
    notes: ['Extracted: $query'],
  );
}

/// Walks a dot-separated [path] of map keys and numeric list indices
/// (`findings.0.path`) into [jsonValue] (the ported subset of omp's
/// jq-style `applyQuery`).
Object? _walkJsonPath(Object? jsonValue, String path, String id) {
  var current = jsonValue;
  for (final segment in path.split('.')) {
    if (segment.isEmpty) continue;
    current = _descendJsonSegment(current, segment, path, id);
  }
  return current;
}

/// One step of the dot-path walk: a map key, a numeric list index, or a
/// failure when [current] is a scalar.
Object? _descendJsonSegment(
  Object? current,
  String segment,
  String path,
  String id,
) {
  if (current is Map) {
    return _descendMapKey(current, segment, path, id);
  }
  if (current is List) {
    return _descendListIndex(current, segment, path, id);
  }
  throw AgentUrlException(
    'Path "$path" not found in $id: "$segment" descends into a scalar',
  );
}

/// The value of [segment] in [current], which must contain the key.
Object? _descendMapKey(Map current, String segment, String path, String id) {
  if (!current.containsKey(segment)) {
    throw AgentUrlException('Path "$path" not found in $id: no key "$segment"');
  }
  return current[segment];
}

/// The element at numeric [segment] in [current], which must be in range.
Object? _descendListIndex(
  List current,
  String segment,
  String path,
  String id,
) {
  final index = int.tryParse(segment);
  if (index == null || index < 0 || index >= current.length) {
    throw AgentUrlException(
      'Path "$path" not found in $id: no index "$segment"',
    );
  }
  return current[index];
}
