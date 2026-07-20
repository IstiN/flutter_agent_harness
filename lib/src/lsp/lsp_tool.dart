/// The `lsp` tool: language-server diagnostics, definition, references,
/// and rename for the agent (a reduced port of oh-my-pi's `lsp` tool,
/// `packages/coding-agent/src/lsp/index.ts`).
///
/// Ops (`op` argument):
///
/// - `diagnostics {path}` — open the file and wait briefly for fresh
///   `publishDiagnostics`; renders `OK` or a severity-sorted list.
/// - `definition {path, line?, character?}` — `textDocument/definition`;
///   renders `file:line:col` locations with the target source line.
/// - `references {path, line?, character?}` — `textDocument/references`
///   (declaration included), same rendering.
/// - `rename {path, line?, character?, newName}` — `textDocument/rename`;
///   the returned `WorkspaceEdit` is applied atomically through the
///   [ExecutionEnv] so barrel files and imports update together, then
///   synced back to the server. Per-file edit counts are reported (omp's
///   `edits.ts` shape).
///
/// `line`/`character` are 1-indexed and default to 1. Reductions from omp:
/// only the four ops above (no hover/symbols/code actions/rename_file/
/// status/reload/capabilities/request), no `symbol`-based column
/// resolution, no glob diagnostics, no preview mode for rename, no
/// per-call timeout argument.
library;

import 'dart:async';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../env/execution_env.dart';
import '../prompts/prompts.g.dart';
import 'lsp_client.dart';
import 'lsp_config.dart';
import 'lsp_edits.dart';
import 'lsp_manager.dart';
import 'lsp_transport.dart';
import 'lsp_types.dart';

/// How long `diagnostics` waits for a fresh publish after opening a file
/// (omp's `SINGLE_DIAGNOSTICS_WAIT_TIMEOUT_MS`).
const defaultDiagnosticsWait = Duration(seconds: 3);

/// Max diagnostics rendered (omp's `DIAGNOSTIC_MESSAGE_LIMIT`).
const _diagnosticLimit = 50;

/// Max locations rendered for definition/references.
const _locationLimit = 50;

/// Configuration for the `lsp` tool; one per agent session (the client
/// pool is session-scoped through it, like the task tool's stores).
final class LspToolConfig {
  /// Creates an [LspToolConfig]. Exactly one of [manager] (tests/hosts
  /// drive the lifecycle) or the factory fields (the tool creates and owns
  /// the manager lazily) is used.
  const LspToolConfig({
    required this.transportFactory,
    this.config,
    this.processId,
    this.requestTimeout = defaultLspRequestTimeout,
    this.initTimeout = defaultLspRequestTimeout,
    this.diagnosticsWait = defaultDiagnosticsWait,
    this.idleTimeout,
    this.manager,
  });

  /// Spawns language servers. The io-side factory lives in `lib/io.dart`;
  /// hosts without process support (web) simply do not register the tool.
  final LspTransportFactory transportFactory;

  /// The server map. When null, [LspConfig.load] merges `.fah/lsp.json`
  /// over the built-in Dart defaults on first use.
  final LspConfig? config;

  /// Host process id advertised to servers (they exit when it dies).
  final int? processId;

  /// Default request timeout.
  final Duration requestTimeout;

  /// Initialize-handshake timeout.
  final Duration initTimeout;

  /// How long `diagnostics` waits for a fresh publish.
  final Duration diagnosticsWait;

  /// Idle shutdown timeout override; defaults to [LspConfig.idleTimeout].
  final Duration? idleTimeout;

  /// A prebuilt manager; when set, the fields above (except
  /// [diagnosticsWait]) are ignored.
  final LspClientManager? manager;
}

/// Creates the `lsp` tool bound to [env]. Registered from `builtinTools`
/// only when the host supplies an [LspToolConfig] — process-capable envs
/// (CLI/desktop) do; web/stub construction leaves the tool out.
AgentTool lspTool(ExecutionEnv env, {required LspToolConfig config}) {
  Future<LspClientManager>? managerFuture;
  Future<LspClientManager> ensureManager() {
    final injected = config.manager;
    if (injected != null) return Future.value(injected);
    return managerFuture ??= () async {
      final loaded = config.config ?? await LspConfig.load(env);
      return LspClientManager(
        env: env,
        config: loaded,
        transportFactory: config.transportFactory,
        processId: config.processId,
        requestTimeout: config.requestTimeout,
        initTimeout: config.initTimeout,
        idleTimeout: config.idleTimeout,
      );
    }();
  }

  return AgentTool(
    name: 'lsp',
    label: 'lsp',
    tier: ApprovalTier.write,
    description: lspToolDescriptionPrompt,
    parameters: const {
      'type': 'object',
      'properties': {
        'op': {
          'type': 'string',
          'enum': ['diagnostics', 'definition', 'references', 'rename'],
          'description': 'The language-server operation to run',
        },
        'path': {
          'type': 'string',
          'description':
              'File to inspect (relative or absolute). For rename, the file '
              'containing the symbol',
        },
        'line': {
          'type': 'integer',
          'description':
              '1-indexed line of the symbol (default 1); used by '
              'definition/references/rename',
        },
        'character': {
          'type': 'integer',
          'description':
              '1-indexed character (column) of the symbol (default 1); '
              'used by definition/references/rename',
        },
        'newName': {
          'type': 'string',
          'description': 'The new identifier (required for rename)',
        },
      },
      'required': ['op', 'path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final op = arguments['op'] as String;
      final path = arguments['path'] as String;
      final line = (arguments['line'] as num?)?.toInt() ?? 1;
      final character = (arguments['character'] as num?)?.toInt() ?? 1;
      final newName = arguments['newName'] as String?;

      if (op == 'rename' && (newName == null || newName.isEmpty)) {
        return ToolExecutionResult.text(
          'newName is required for the rename op',
        );
      }

      final manager = await ensureManager();
      final absolute = (await env.absolutePath(path)).valueOrNull ?? path;

      final LspClient client;
      try {
        client = await manager.clientForFile(absolute);
      } on LspNoServerException {
        return ToolExecutionResult.text(
          'No LSP server configured for $path. Configure servers in '
          '$lspConfigFileName.',
        );
      } on LspServerUnavailableException catch (error) {
        return ToolExecutionResult.text('LSP server unavailable: $error');
      }
      cancelToken?.throwIfCancelled();

      final read = await env.readTextFile(absolute);
      if (read.isErr) throw StateError('${read.errorOrNull}');
      final server = client.config;
      final uri = fileToUri(absolute);
      final capturedVersion = client.diagnosticsVersion;
      if (op == 'diagnostics') {
        // Sync the on-disk content so the server re-analyzes and publishes
        // fresh diagnostics (omp's refreshFile); opens the file when new.
        client.syncContent(
          absolute,
          read.valueOrNull!,
          server.languageIdFor(path),
        );
      } else {
        client.ensureOpen(
          absolute,
          read.valueOrNull!,
          server.languageIdFor(path),
        );
      }
      cancelToken?.throwIfCancelled();

      try {
        return await switch (op) {
          'diagnostics' => _diagnostics(
            env,
            client,
            absolute,
            uri,
            capturedVersion,
            config.diagnosticsWait,
          ),
          'definition' => _locations(
            env,
            client,
            'textDocument/definition',
            uri,
            line,
            character,
            'definition',
          ),
          'references' => _locations(
            env,
            client,
            'textDocument/references',
            uri,
            line,
            character,
            'reference',
          ),
          'rename' => _rename(
            env,
            client,
            absolute,
            uri,
            line,
            character,
            newName!,
          ),
          _ => throw StateError('unknown lsp op: $op'),
        };
      } on LspRequestException catch (error) {
        throw StateError('LSP error: ${error.message}');
      }
    },
  );
}

/// Waits for a diagnostics publish newer than [capturedVersion] (bounded
/// by [wait]), then renders the cached diagnostics for [uri].
Future<ToolExecutionResult> _diagnostics(
  ExecutionEnv env,
  LspClient client,
  String absolute,
  String uri,
  int capturedVersion,
  Duration wait,
) async {
  if (client.diagnosticsVersion <= capturedVersion) {
    final completer = Completer<void>();
    late final StreamSubscription<String> sub;
    sub = client.diagnosticsStream.listen((_) {
      if (client.diagnosticsVersion > capturedVersion &&
          !completer.isCompleted) {
        completer.complete();
      }
    });
    final timer = Timer(wait, () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    timer.cancel();
    await sub.cancel();
  }

  final found = client.diagnostics[uri] ?? const <LspDiagnostic>[];
  if (found.isEmpty) return ToolExecutionResult.text('OK');

  final sorted = [...found]
    ..sort((a, b) {
      final bySeverity = a.severity.wireValue - b.severity.wireValue;
      if (bySeverity != 0) return bySeverity;
      final byLine = a.range.start.line - b.range.start.line;
      return byLine != 0
          ? byLine
          : a.range.start.character - b.range.start.character;
    });
  final counts = <LspDiagnosticSeverity, int>{};
  for (final diagnostic in sorted) {
    counts[diagnostic.severity] = (counts[diagnostic.severity] ?? 0) + 1;
  }
  final summary = [
    for (final severity in LspDiagnosticSeverity.values)
      if (counts[severity] case final count?) '$count ${severity.label}(s)',
  ].join(', ');

  final buffer = StringBuffer()
    ..writeln('${formatPathRelativeToCwd(absolute, env.cwd)}: $summary:');
  final shown = sorted.take(_diagnosticLimit).toList();
  for (final diagnostic in shown) {
    final line = diagnostic.range.start.line + 1;
    final col = diagnostic.range.start.character + 1;
    buffer.write(
      '  L$line:$col [${diagnostic.severity.label}] '
      '${diagnostic.message}',
    );
    if (diagnostic.source != null) buffer.write(' (${diagnostic.source})');
    buffer.writeln();
  }
  if (sorted.length > shown.length) {
    buffer.writeln('  ... and ${sorted.length - shown.length} more');
  }
  return ToolExecutionResult.text(buffer.toString().trimRight());
}

/// Runs a location-returning request (`definition`/`references`) and
/// renders the results (omp's `file:line:col` + target source line).
Future<ToolExecutionResult> _locations(
  ExecutionEnv env,
  LspClient client,
  String method,
  String uri,
  int line,
  int character,
  String noun,
) async {
  final params = <String, dynamic>{
    'textDocument': {'uri': uri},
    'position': {'line': line - 1, 'character': character - 1},
    if (method == 'textDocument/references')
      'context': {'includeDeclaration': true},
  };
  final result = await client.request(method, params);
  final locations = normalizeLocationResult(result);
  if (locations.isEmpty) {
    return ToolExecutionResult.text('No ${noun}s found');
  }

  final shown = locations.take(_locationLimit).toList();
  final buffer = StringBuffer()..writeln('Found ${locations.length} $noun(s):');
  final contentCache = <String, List<String>>{};
  for (final location in shown) {
    buffer.writeln('  ${location.format(env.cwd)}');
    final sourceLine = await _sourceLine(env, location, contentCache);
    if (sourceLine != null && sourceLine.trim().isNotEmpty) {
      buffer.writeln('    ${sourceLine.trim()}');
    }
  }
  if (locations.length > shown.length) {
    buffer.writeln(
      '  ... ${locations.length - shown.length} more location(s) not shown',
    );
  }
  return ToolExecutionResult.text(buffer.toString().trimRight());
}

/// Reads the 0-indexed target line of [location] (cached per file).
Future<String?> _sourceLine(
  ExecutionEnv env,
  LspLocation location,
  Map<String, List<String>> cache,
) async {
  final path = uriToFile(location.uri);
  var lines = cache[path];
  if (lines == null) {
    final read = await env.readTextFile(path);
    if (read.isErr) return null;
    lines = read.valueOrNull!.split('\n');
    cache[path] = lines;
  }
  final index = location.range.start.line;
  return index < lines.length ? lines[index] : null;
}

/// Runs `textDocument/rename` and applies the returned workspace edit
/// atomically (omp's `rename` apply path).
Future<ToolExecutionResult> _rename(
  ExecutionEnv env,
  LspClient client,
  String absolute,
  String uri,
  int line,
  int character,
  String newName,
) async {
  final result = await client.request('textDocument/rename', {
    'textDocument': {'uri': uri},
    'position': {'line': line - 1, 'character': character - 1},
    'newName': newName,
  });
  final edit = LspWorkspaceEdit.fromJson(result);
  if (edit == null || edit.isEmpty) {
    return ToolExecutionResult.text('Rename returned no edits');
  }

  final applied = await applyWorkspaceEdit(
    env,
    edit,
    openFileVersions: client.openFiles,
  );

  // Sync the changed documents back so the server's view matches disk.
  for (final change in applied) {
    if (!client.openFiles.containsKey(fileToUri(change.path))) continue;
    final read = await env.readTextFile(change.path);
    if (read.isErr) continue;
    client.syncContent(
      change.path,
      read.valueOrNull!,
      client.config.languageIdFor(change.path),
    );
  }

  final buffer = StringBuffer()
    ..writeln('Applied rename to ${applied.length} file(s):');
  for (final change in applied) {
    buffer.writeln('  ${change.format(env.cwd)}');
  }
  if (edit.skippedResourceOps > 0) {
    buffer.writeln(
      '  [${edit.skippedResourceOps} resource operation(s) '
      '(create/rename/delete) skipped: not supported]',
    );
  }
  return ToolExecutionResult.text(buffer.toString().trimRight());
}
