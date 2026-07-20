/// LSP server configuration: the extension→server map in oh-my-pi's
/// `defaults.json` shape, plus loading and server selection (a reduced port
/// of `packages/coding-agent/src/lsp/config.ts`).
///
/// The built-in default registers the Dart analysis server for `.dart`:
///
/// ```json
/// {
///   "servers": {
///     "dart": {
///       "command": "dart",
///       "args": ["language-server", "--protocol=lsp"],
///       "fileTypes": [".dart"],
///       "rootMarkers": ["pubspec.yaml", "pubspec.lock"],
///       "initOptions": {"closingLabels": true, "outline": true,
///         "flutterOutline": true}
///     }
///   }
/// }
/// ```
///
/// A project may add servers or override the defaults through
/// `.fah/lsp.json` in the workspace root (JSON only — omp's YAML variant,
/// user-level config dirs, plugin sources, and auto-detect beyond the
/// built-ins are not ported). Entries merge field-wise over the defaults.
library;

import 'dart:convert';

import '../env/execution_env.dart';

/// Config file consulted in the workspace root (documented location; see
/// [LspConfig.load]).
const lspConfigFileName = '.fah/lsp.json';

/// One language server definition (omp's `ServerConfig`, reduced).
final class LspServerConfig {
  /// Creates an [LspServerConfig].
  const LspServerConfig({
    required this.name,
    required this.command,
    this.args = const [],
    this.fileTypes = const [],
    this.rootMarkers = const [],
    this.initOptions = const {},
    this.settings = const {},
    this.disabled = false,
    this.languageId,
  });

  /// Parses one `servers` entry from JSON. Returns null when required
  /// fields are missing or invalid (omp's `normalizeServerConfig`).
  static LspServerConfig? fromJson(String name, Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final command = json['command'];
    final fileTypes = _stringList(json['fileTypes']);
    final rootMarkers = _stringList(json['rootMarkers']);
    if (command is! String || command.isEmpty) return null;
    if (fileTypes == null || rootMarkers == null) return null;
    final initOptions = json['initOptions'] ?? json['initializationOptions'];
    return LspServerConfig(
      name: name,
      command: command,
      args: _stringList(json['args']) ?? const [],
      fileTypes: fileTypes,
      rootMarkers: rootMarkers,
      initOptions: initOptions is Map<String, dynamic> ? initOptions : const {},
      settings: json['settings'] is Map<String, dynamic>
          ? json['settings'] as Map<String, dynamic>
          : const {},
      disabled: json['disabled'] == true,
      languageId: json['languageId'] is String
          ? json['languageId'] as String
          : null,
    );
  }

  static List<String>? _stringList(Object? value) {
    if (value is! List) return null;
    final items = [
      for (final entry in value)
        if (entry is String && entry.isNotEmpty) entry,
    ];
    return items.isEmpty ? null : items;
  }

  /// Merges an override entry over this config (omp's `mergeServers`):
  /// present fields in [overrideJson] win, absent fields keep the base
  /// value. Returns null when the merged result is invalid.
  LspServerConfig? mergedWith(Object? overrideJson) {
    if (overrideJson is! Map<String, dynamic>) return null;
    final candidate = <String, dynamic>{
      'command': command,
      'args': args,
      'fileTypes': fileTypes,
      'rootMarkers': rootMarkers,
      'initOptions': initOptions,
      'settings': settings,
      'disabled': disabled,
      if (languageId != null) 'languageId': languageId,
      ...overrideJson,
    };
    return LspServerConfig.fromJson(name, candidate);
  }

  /// Server name (the `servers` map key).
  final String name;

  /// Executable to spawn (resolved against `PATH` by the transport).
  final String command;

  /// Command arguments.
  final List<String> args;

  /// File extensions (with dot, e.g. `.dart`) or exact basenames this
  /// server handles.
  final List<String> fileTypes;

  /// Marker files that identify a workspace root for this server.
  final List<String> rootMarkers;

  /// `initializationOptions` sent with the `initialize` request.
  final Map<String, dynamic> initOptions;

  /// Settings answered to `workspace/configuration` pulls and pushed via
  /// `workspace/didChangeConfiguration` after init.
  final Map<String, dynamic> settings;

  /// Disabled servers are never started.
  final bool disabled;

  /// The `languageId` sent in `textDocument/didOpen`. Defaults to the
  /// file's extension without the dot (`.dart` → `dart`).
  final String? languageId;

  /// Resolves the language id for [path] (see [languageId]).
  String languageIdFor(String path) {
    final configured = languageId;
    if (configured != null) return configured;
    final base = path.split('/').last;
    final dot = base.lastIndexOf('.');
    return dot == -1 ? base : base.substring(dot + 1);
  }
}

/// The resolved server configuration for a workspace (omp's `LspConfig`).
final class LspConfig {
  /// Creates an [LspConfig].
  const LspConfig({
    required this.servers,
    this.idleTimeout = defaultIdleTimeout,
    this.warnings = const [],
  });

  /// The built-in defaults: the Dart analysis server only. Other servers
  /// join through `.fah/lsp.json`.
  factory LspConfig.defaults() => const LspConfig(
    servers: {
      'dart': LspServerConfig(
        name: 'dart',
        command: 'dart',
        args: ['language-server', '--protocol=lsp'],
        fileTypes: ['.dart'],
        rootMarkers: ['pubspec.yaml', 'pubspec.lock'],
        initOptions: {
          'closingLabels': true,
          'outline': true,
          'flutterOutline': true,
        },
      ),
    },
  );

  /// Loads the configuration for [env]: the built-in defaults merged with
  /// `.fah/lsp.json` from [env]'s cwd when present. A malformed config file
  /// is reported in [warnings] and otherwise ignored (never fatal).
  static Future<LspConfig> load(ExecutionEnv env) async {
    final base = LspConfig.defaults();
    final read = await env.readTextFile(lspConfigFileName);
    if (read.isErr) return base;
    final Object? parsed;
    try {
      parsed = jsonDecode(read.valueOrNull!);
    } on Object catch (error) {
      return LspConfig(
        servers: base.servers,
        warnings: ['ignoring malformed $lspConfigFileName: $error'],
      );
    }
    if (parsed is! Map<String, dynamic>) {
      return LspConfig(
        servers: base.servers,
        warnings: ['ignoring $lspConfigFileName: top level must be an object'],
      );
    }

    final warnings = <String>[];
    final servers = Map<String, LspServerConfig>.of(base.servers);
    final rawServers = parsed['servers'];
    if (rawServers is Map<String, dynamic>) {
      for (final entry in rawServers.entries) {
        final existing = servers[entry.key];
        final merged = existing != null
            ? existing.mergedWith(entry.value)
            : LspServerConfig.fromJson(entry.key, entry.value);
        if (merged == null) {
          warnings.add(
            'ignoring invalid LSP server config "${entry.key}" '
            '(missing required fields: command, fileTypes, rootMarkers)',
          );
        } else {
          servers[entry.key] = merged;
        }
      }
    }

    var idleTimeout = base.idleTimeout;
    final idleTimeoutMs = parsed['idleTimeoutMs'];
    if (idleTimeoutMs is num) {
      idleTimeout = idleTimeoutMs <= 0
          ? Duration.zero
          : Duration(milliseconds: idleTimeoutMs.toInt());
    }
    return LspConfig(
      servers: servers,
      idleTimeout: idleTimeout,
      warnings: warnings,
    );
  }

  /// Configured servers by name.
  final Map<String, LspServerConfig> servers;

  /// Idle timeout after which unused servers are shut down. [Duration.zero]
  /// disables the sweep.
  final Duration idleTimeout;

  /// Non-fatal problems encountered while loading.
  final List<String> warnings;

  /// Default idle timeout: 5 minutes (omp disables the sweep by default;
  /// the kanban design calls for idle shutdown, so it is on here and
  /// configurable via `idleTimeoutMs` in `.fah/lsp.json`).
  static const defaultIdleTimeout = Duration(minutes: 5);

  /// Finds the server handling [path], matching `fileTypes` against the
  /// lowercased extension or the exact basename (omp's
  /// `getServerForFile`, reduced to the first match; linter ordering is not
  /// ported). Disabled servers never match.
  LspServerConfig? serverForFile(String path) {
    final base = path.split('/').last.toLowerCase();
    final dot = base.lastIndexOf('.');
    final ext = dot == -1 ? '' : base.substring(dot);
    for (final server in servers.values) {
      if (server.disabled) continue;
      for (final fileType in server.fileTypes) {
        final normalized = fileType.toLowerCase();
        if (normalized == ext || normalized == base) return server;
      }
    }
    return null;
  }

  /// Resolves the workspace root for [path] under [server]: the nearest
  /// ancestor directory (starting at the file's directory) containing one
  /// of the server's root markers (omp's `hasRootMarkerAncestor` used as a
  /// root locator). Falls back to [env]'s cwd.
  Future<String> workspaceRootFor(
    ExecutionEnv env,
    String path,
    LspServerConfig server,
  ) async {
    final absolute = await env.absolutePath(path);
    var dir = absolute.valueOrNull ?? path;
    final slash = dir.lastIndexOf('/');
    dir = slash <= 0 ? '/' : dir.substring(0, slash);
    while (true) {
      for (final marker in server.rootMarkers) {
        final candidate = dir == '/' ? '/$marker' : '$dir/$marker';
        final exists = await env.exists(candidate);
        if (exists.isOk && exists.valueOrNull == true) return dir;
      }
      if (dir == '/') break;
      final parent = dir.lastIndexOf('/');
      final next = parent <= 0 ? '/' : dir.substring(0, parent);
      if (next == dir) break;
      dir = next;
    }
    return env.cwd;
  }
}
