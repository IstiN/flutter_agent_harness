/// The config service (issue #29 S3): `check / get / set / paths` over the
/// harness config pair — the user file `~/.fah/config.yaml` and the project
/// `<cwd>/.fah/config.yaml` — on top of the abstract [ExecutionEnv]. No
/// `dart:io`, so the SAME service backs the `config` agent tool on every
/// host (VM, desktop app, browser storage, container) and the
/// `fa config check|path|get|set` CLI wrapper.
///
/// Scope model (the `fa-self-config` skill's precedence rule): the project
/// file is read only for the `memory:`, `cube:` and `tools:` sections and
/// each wins over the user file; every other key lives in the user file
/// only. `set` resolves its scope by default to the project file when one
/// exists in the env cwd, else the user file; an explicit scope always wins.
///
/// Writes are surgical line edits — every unrelated line, including
/// comments, stays byte-identical — and the edited text is parsed back
/// through the REAL section parsers BEFORE it is written, so `set` can never
/// persist a file the next boot would reject. The write itself is one
/// `writeFile` call (the [FileSystem] boundary has no rename; torn-write
/// recovery is the host's last-good-config semantics).
///
/// Purity note: this file deliberately does NOT import `lib/src/cli/
/// cli_config.dart` (it uses `dart:io`). The section validators below call
/// the same pure parser classes the CLI config uses; the two structural
/// validators (`skills:`, `providerTimeouts:`) mirror the private strict
/// parsers in `cli_config.dart` and are pinned to it by unit tests.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../a2a/a2a_config.dart';
import '../cli/custom_providers.dart';
import '../cube/config/cube_settings.dart';
import '../env/execution_env.dart';
import '../exceptions.dart';
import '../mcp/mcp_config.dart';
import '../memory_config.dart';
import '../model_roles/model_roles.dart';
import '../redact/redaction_types.dart';
import '../tools/availability.dart';
import '../ttsr/ttsr.dart';

/// Sections the PROJECT file participates in (each wins over the user file).
const _projectSections = {'memory', 'cube', 'tools'};

/// Every top-level key the runtime config actually reads (the keys
/// `CliConfig.fromYaml` consumes, plus the `roles:` group members). The
/// source-text pin keeping this set honest lives in
/// `test/config/config_service_test.dart`.
const configTopLevelKeys = <String>{
  'provider',
  'model',
  'baseUrl',
  'mode',
  'approvalMode',
  'allowedTools',
  'prompts',
  'roles',
  'modelOverrides',
  'retry',
  'ttsr',
  'memory',
  'cube',
  'tools',
  'redact',
  'customProviders',
  'models',
  'mcp',
  'a2a',
  'providerTimeouts',
  'skills',
};

/// Top-level keys that carry a plain string value.
const _scalarKeys = {'provider', 'model', 'baseUrl', 'mode', 'approvalMode'};

/// Members of the roles group — parsed together by one
/// `ModelRolesConfig.fromYaml` call over the whole document.
const _rolesGroupKeys = {'roles', 'modelOverrides', 'retry'};

/// Write scope of a `set`.
enum ConfigScope { global, project }

/// One config problem (or dead-config note) found by [ConfigService.check].
final class ConfigDiagnostic {
  const ConfigDiagnostic(this.file, this.message);

  /// The file the diagnostic came from.
  final String file;

  /// The named diagnostic (section + reason).
  final String message;

  @override
  String toString() => '$file: $message';
}

/// Result of [ConfigService.check].
final class ConfigCheckReport {
  final errors = <ConfigDiagnostic>[];
  final warnings = <ConfigDiagnostic>[];
  final notes = <String>[];

  /// True when no error was found (warnings do not fail the check — they
  /// mirror the runtime, which silently ignores unknown keys).
  bool get ok => errors.isEmpty;
}

/// Renders a [ConfigCheckReport] as the canonical multi-line text both
/// surfaces print: `fa config check` (exit code 1 on failure) and the
/// `config` agent tool's `check` op — one rendering, never two.
String renderConfigCheckReport(ConfigCheckReport report) {
  return '${[for (final error in report.errors) 'error: $error', for (final warning in report.warnings) 'warning: $warning', for (final note in report.notes) 'note: $note', report.ok ? 'config check: ok' : 'config check: failed'].join('\n')}\n';
}

/// Result of [ConfigService.get].
final class ConfigGetResult {
  const ConfigGetResult({
    required this.key,
    required this.found,
    this.display,
    this.scope,
    this.file,
  });

  /// The requested dotted key.
  final String key;

  /// Whether an effective value exists (project scope wins per section).
  final bool found;

  /// The effective value rendered (scalars verbatim, maps/lists compact
  /// JSON). Null when [found] is false.
  final String? display;

  /// Which file the value came from: `global` or `project`.
  final String? scope;

  /// The file path the value came from.
  final String? file;
}

/// Result of [ConfigService.set].
final class ConfigSetResult {
  const ConfigSetResult({
    required this.key,
    required this.file,
    required this.scope,
    required this.oldDisplay,
    required this.newDisplay,
    required this.application,
  });

  /// The dotted key that was written.
  final String key;

  /// The file that was edited.
  final String file;

  /// `global` or `project`.
  final String scope;

  /// The previous value display, `(absent)` when the key was not set.
  final String oldDisplay;

  /// The value that was written.
  final String newDisplay;

  /// Whether/when the change applies at runtime (live re-read surface or
  /// next boot).
  final String application;
}

/// One config file location reported by [ConfigService.paths].
final class ConfigPathInfo {
  const ConfigPathInfo(this.label, this.path, this.exists);

  /// Human label (`global config`, `project config`, `project rules`, ...).
  final String label;

  /// Absolute path (or a host note in place of the path).
  final String path;

  /// Whether the file exists.
  final bool exists;
}

/// The config service over one [ExecutionEnv]. See the library docs.
final class ConfigService {
  /// Creates the service. [homeDir] may be null on hosts without a home
  /// directory (web) — the global scope answers "not available" instead of
  /// guessing a path.
  ConfigService({required this.env, this.homeDir});

  /// The execution env the service reads and writes through.
  final ExecutionEnv env;

  /// The user home directory, or null when the host has none.
  final String? homeDir;

  /// The user config file, or null when the host has no home directory.
  String? get globalConfigPath =>
      homeDir == null ? null : '$homeDir/.fah/config.yaml';

  /// The project config file (resolved against the env cwd).
  String get projectConfigPath => '${env.cwd}/.fah/config.yaml';

  /// Validates both config files with the real section parsers. Missing
  /// files are fine (defaults apply); syntax errors, strict-section schema
  /// errors and bad scalar types are errors; unknown top-level keys are
  /// warnings (the runtime silently ignores them — the check does not).
  Future<ConfigCheckReport> check() async {
    final report = ConfigCheckReport();
    final globalPath = globalConfigPath;
    if (globalPath == null) {
      report.notes.add(
        'global scope unavailable on this host (no home directory)',
      );
    } else {
      final text = await _readTextOrNull(globalPath);
      if (text == null) {
        report.notes.add('global config absent (defaults apply): $globalPath');
      } else {
        _collectDiagnostics(text, globalPath, report.errors, report.warnings);
      }
    }
    final projectText = await _readTextOrNull(projectConfigPath);
    if (projectText == null) {
      report.notes.add(
        'project config absent (defaults apply): $projectConfigPath',
      );
    } else {
      final projectWarnings = <ConfigDiagnostic>[];
      _collectDiagnostics(
        projectText,
        projectConfigPath,
        report.errors,
        projectWarnings,
      );
      report.warnings.addAll(projectWarnings);
      // Dead config: sections the project file is never read for.
      final doc = _tryParse(projectText);
      if (doc != null) {
        for (final key in doc.keys) {
          if (!_projectSections.contains('$key')) {
            report.warnings.add(
              ConfigDiagnostic(
                projectConfigPath,
                '"$key" in the project file is dead config — only '
                '${_projectSections.join('/')} are read from here',
              ),
            );
          }
        }
      }
    }
    return report;
  }

  /// Resolves one dotted [key] (`memory.projectPath`, `tools.web_search`,
  /// `provider`, `mcp.servers.fs.url`, ...) to its effective value. Project
  /// scope wins for the project-capable sections; everything else comes
  /// from the user file. Unknown top-level keys throw — `get` must catch
  /// typos, not report them as "not set".
  Future<ConfigGetResult> get(String key) async {
    final segments = _parseKey(key);
    final top = segments.first;
    if (!configTopLevelKeys.contains(top)) {
      throw ConfigException(
        'unknown config key: "$top" (known top-level keys: '
        '${configTopLevelKeys.join(', ')})',
      );
    }
    if (_projectSections.contains(top)) {
      final projectDoc = await _readTextOrNull(projectConfigPath) ?? '';
      final projectValue = _walk(_tryParse(projectDoc), segments);
      if (projectValue != null) {
        return ConfigGetResult(
          key: key,
          found: true,
          display: _display(projectValue),
          scope: 'project',
          file: projectConfigPath,
        );
      }
    }
    final globalText = globalConfigPath == null
        ? ''
        : await _readTextOrNull(globalConfigPath!) ?? '';
    final globalValue = _walk(_tryParse(globalText), segments);
    if (globalValue != null) {
      return ConfigGetResult(
        key: key,
        found: true,
        display: _display(globalValue),
        scope: 'global',
        file: globalConfigPath,
      );
    }
    return ConfigGetResult(key: key, found: false);
  }

  /// Writes [value] (rendered as a YAML scalar) at the dotted [key] in the
  /// resolved scope file. The edited text is validated with the real
  /// parsers BEFORE the write, so a bad value throws and nothing is
  /// persisted. Missing files are created with the minimal section (never a
  /// half-written document).
  Future<ConfigSetResult> set(
    String key,
    String value, {
    ConfigScope? scope,
  }) async {
    final segments = _parseKey(key);
    if (value.trim().isEmpty) {
      throw ConfigException(
        'empty value for "$key" — removing a key is a manual file edit',
      );
    }
    final resolved = await resolveWriteScope(scope, key: key);
    if (resolved == ConfigScope.project &&
        !_projectSections.contains(segments.first)) {
      throw ConfigException(
        '"${segments.first}" is only read from the user file — the project '
        'file participates in ${_projectSections.join('/')} only. Write it '
        'to the user file: fa config set $key <value> --global',
      );
    }
    final file = switch (resolved) {
      ConfigScope.project => projectConfigPath,
      ConfigScope.global => globalConfigPath,
    };
    if (file == null) {
      throw const ConfigException(
        'global scope unavailable on this host (no home directory)',
      );
    }
    final text = await _readTextOrNull(file) ?? '';
    final oldDisplay = _lookupDisplay(text, segments) ?? '(absent)';
    final edited = upsertYamlPath(text, segments, renderYamlScalar(value));
    // New or previously newline-less files still end with a newline.
    final normalized = edited.isEmpty || edited.endsWith('\n')
        ? edited
        : '$edited\n';
    // Never persist a file the next boot would reject.
    final errors = <ConfigDiagnostic>[];
    _collectDiagnostics(normalized, file, errors, <ConfigDiagnostic>[]);
    if (errors.isNotEmpty) {
      throw ConfigException(errors.map((e) => e.message).join('; '));
    }
    switch (await env.writeFile(file, normalized)) {
      case Err(:final error):
        throw ConfigException('cannot write $file: $error');
      case Ok():
        break;
    }
    return ConfigSetResult(
      key: key,
      file: file,
      scope: resolved.name,
      oldDisplay: oldDisplay,
      newDisplay: value,
      application: applicationNote(segments.first),
    );
  }

  /// Resolves the write scope: an explicit [scope] wins. By default the
  /// project-capable sections (memory/cube/tools) belong in the project
  /// file (created when absent); everything else belongs in the user file.
  Future<ConfigScope> resolveWriteScope(
    ConfigScope? scope, {
    String? key,
  }) async {
    if (scope != null) return scope;
    if (key != null && _projectSections.contains(key.split('.').first)) {
      return ConfigScope.project;
    }
    return ConfigScope.global;
  }

  /// The config file locations and whether each exists.
  Future<List<ConfigPathInfo>> paths() async {
    Future<ConfigPathInfo> entry(String label, String path) async =>
        ConfigPathInfo(label, path, await _exists(path));
    return [
      if (homeDir != null)
        await entry('global config', '$homeDir/.fah/config.yaml')
      else
        const ConfigPathInfo(
          'global config',
          '~/.fah/config.yaml (no home directory on this host)',
          false,
        ),
      await entry('project config', projectConfigPath),
      await entry('project rules', '${env.cwd}/.fah/rules.yaml'),
      await entry('project lsp', '${env.cwd}/.fah/lsp.json'),
      await entry('project packages', '${env.cwd}/.fah/packages.yaml'),
      if (homeDir != null)
        await entry('dap config', '$homeDir/.dap/config.json'),
    ];
  }

  // ---------------------------------------------------------------------

  Future<bool> _exists(String path) async {
    final result = await env.exists(path);
    return switch (result) {
      Ok(:final value) => value,
      Err() => false,
    };
  }

  /// The file text, or null when the file does not exist. Other read
  /// failures surface as [ConfigException] — silently editing a file we
  /// could not read would destroy config.
  Future<String?> _readTextOrNull(String path) async {
    if (!await _exists(path)) return null;
    final result = await env.readTextFile(path);
    switch (result) {
      case Ok(:final value):
        return value;
      case Err(:final error):
        throw ConfigException('cannot read $path: $error');
    }
  }

  static YamlMap? _tryParse(String text) {
    if (text.trim().isEmpty) return null;
    final doc = loadYaml(text);
    return doc is YamlMap ? doc : null;
  }

  /// Parses [key] into non-empty dotted segments.
  List<String> _parseKey(String key) {
    final segments = key.split('.').map((s) => s.trim()).toList();
    if (segments.any((s) => s.isEmpty)) {
      throw ConfigException(
        'invalid config key: "$key" (dotted path expected)',
      );
    }
    return segments;
  }

  /// Walks [segments] through [doc]; null when any hop is missing.
  static Object? _walk(YamlMap? doc, List<String> segments) {
    Object? node = doc;
    for (final segment in segments) {
      if (node is! YamlMap) return null;
      node = node[segment];
    }
    return node;
  }

  /// The display form of an existing value at [segments] in [text], or null
  /// when the path is absent.
  String? _lookupDisplay(String text, List<String> segments) {
    final doc = _tryParse(text);
    if (doc == null) return null;
    final value = _walk(doc, segments);
    return value == null ? null : _display(value);
  }

  /// Scalars verbatim; collections compact JSON (valid YAML stays readable).
  static String _display(Object? value) => switch (value) {
    YamlScalar() => '${value.value}',
    YamlList() => jsonEncode(value.value),
    YamlMap() => jsonEncode(value.value),
    List() || Map() => jsonEncode(value),
    _ => '$value',
  };
}

/// Renders [raw] as a YAML scalar: booleans/numbers verbatim, plain-safe
/// strings unquoted, everything else JSON-quoted (a JSON string is a valid
/// YAML double-quoted scalar — the same convention the `prompts:` section
/// uses).
String renderYamlScalar(String raw) {
  if (raw == 'true' || raw == 'false' || raw == 'null' || raw == '~') {
    return raw;
  }
  if (int.tryParse(raw) != null) return raw;
  if (double.tryParse(raw) != null) return raw;
  final plainSafe = RegExp(r'^[A-Za-z0-9_.~][A-Za-z0-9_./@+-]*$');
  final uri = RegExp(r'^[a-z][a-z0-9+.-]*://\S*$');
  return plainSafe.hasMatch(raw) || uri.hasMatch(raw) ? raw : jsonEncode(raw);
}

/// Edits [text] so the dotted [segments] path carries [rendered], keeping
/// every unrelated line (including comments) byte-identical:
///
/// - an existing scalar line is rewritten in place, preserving a trailing
///   ` # comment`;
/// - a missing key is inserted at the top of its parent's block;
/// - a missing top-level section is appended at the end of the file;
/// - descending into an inline scalar is a [ConfigException] (type clash).
String upsertYamlPath(String text, List<String> segments, String rendered) {
  final hadTrailingNewline = text.endsWith('\n');
  final lines = text.isEmpty
      ? <String>[]
      : (hadTrailingNewline ? text.substring(0, text.length - 1) : text).split(
          '\n',
        );
  var cursor = 0;
  for (var depth = 0; depth < segments.length; depth++) {
    final indent = '  ' * depth;
    final key = segments[depth];
    final tail = r':(\s.*)?$';
    final pattern = RegExp(
      '^${RegExp.escape(indent)}${RegExp.escape(key)}$tail',
    );
    var found = -1;
    for (var i = cursor; i < lines.length; i++) {
      final line = lines[i];
      if (_indentOf(line) < depth * 2 && i > cursor) break;
      if (pattern.hasMatch(line)) {
        found = i;
        break;
      }
    }
    if (found < 0) {
      // Insert the remaining chain: at EOF for a new top-level section,
      // otherwise at the top of the parent's block.
      final insertAt = depth == 0 ? lines.length : cursor;
      if (depth == 0 && lines.isNotEmpty && lines.last.trim().isNotEmpty) {
        lines.add('');
      }
      for (var d = depth; d < segments.length; d++) {
        final isLeaf = d == segments.length - 1;
        lines.insert(
          insertAt + (d - depth),
          '${'  ' * d}${segments[d]}:${isLeaf ? ' $rendered' : ''}',
        );
      }
      return _join(lines, hadTrailingNewline);
    }
    if (depth == segments.length - 1) {
      final comment = _trailingComment(lines[found]);
      lines[found] = '$indent$key: $rendered$comment';
      return _join(lines, hadTrailingNewline);
    }
    final inline = _inlineValue(lines[found]);
    if (inline != null && inline.isNotEmpty) {
      throw ConfigException(
        '"${segments.sublist(0, depth + 1).join('.')}" is a scalar — '
        'cannot set a deeper key under it',
      );
    }
    cursor = found + 1;
  }
  // Unreachable: the leaf always returns inside the loop.
  throw StateError('upsertYamlPath fell through');
}

int _indentOf(String line) {
  var count = 0;
  while (count < line.length && line[count] == ' ') {
    count++;
  }
  return count;
}

String _join(List<String> lines, bool trailingNewline) =>
    lines.isEmpty ? '' : '${lines.join('\n')}${trailingNewline ? '\n' : ''}';

/// The ` # ...` tail of a `key: value # comment` line, quote-free comments
/// only (a quoted value containing ` #` is left alone rather than
/// mis-split).
String _trailingComment(String line) {
  final match = RegExp('\\s+#[^\']*\$').firstMatch(line);
  return match == null ? '' : match.group(0)!;
}

/// The inline value of a `key: value` line (null when the line declares a
/// nested block), comments stripped.
String? _inlineValue(String line) {
  final colon = line.indexOf(':');
  if (colon < 0) return null;
  var value = line.substring(colon + 1);
  final comment = RegExp('\\s+#[^\']*\$').firstMatch(value);
  if (comment != null) value = value.substring(0, comment.start);
  return value.trim();
}

/// Whether/when a change to [section] applies at runtime.
String applicationNote(String section) => switch (section) {
  'memory' =>
    'applies live — the memory controller re-reads the section on the next '
        'memory operation',
  'tools' =>
    'applies live after /tools reload (and for every session started after '
        'the change)',
  'mcp' => 'applies live after /mcp reload',
  'cube' => 'applies live via /cube reload, otherwise at next boot',
  _ => 'applies at next boot',
};

/// Collects diagnostics for one config file: syntax errors, unknown keys
/// (warnings), strict-section schema errors and bad scalars (errors).
void _collectDiagnostics(
  String text,
  String label,
  List<ConfigDiagnostic> errors,
  List<ConfigDiagnostic> warnings,
) {
  YamlMap? doc;
  if (text.trim().isNotEmpty) {
    try {
      final parsed = loadYaml(text);
      if (parsed is YamlMap) {
        doc = parsed;
      } else {
        errors.add(ConfigDiagnostic(label, 'config root must be a yaml map'));
        return;
      }
    } on YamlException catch (error) {
      errors.add(ConfigDiagnostic(label, 'invalid yaml: ${error.message}'));
      return;
    }
  }
  if (doc == null) return;
  var rolesChecked = false;
  for (final keyNode in doc.keys) {
    final key = '$keyNode';
    final value = doc[keyNode];
    if (!configTopLevelKeys.contains(key)) {
      warnings.add(
        ConfigDiagnostic(
          label,
          'unknown top-level key "$key" (ignored by the runtime)',
        ),
      );
      continue;
    }
    try {
      if (_scalarKeys.contains(key)) {
        // The yaml package hands back plain String scalars (older versions
        // wrap them in YamlScalar) - accept both.
        final scalar = value is YamlScalar ? value.value : value;
        if (scalar is! String || scalar.isEmpty) {
          throw ConfigException('must be a non-empty string');
        }
      } else if (key == 'allowedTools') {
        if (value != null && value is! YamlList) {
          throw ConfigException('must be a list of tool names');
        }
      } else if (_rolesGroupKeys.contains(key)) {
        if (!rolesChecked) {
          rolesChecked = true;
          ModelRolesConfig.fromYaml(doc);
        }
      } else {
        switch (key) {
          case 'memory':
            MemoryConfig.fromYaml(value);
          case 'cube':
            CubeSettings.fromYaml(value);
          case 'tools':
            ToolsConfig.fromYaml(value);
          case 'mcp':
            McpConfig.fromYaml(value);
          case 'redact':
            RedactionConfig.fromYaml(value);
          case 'models':
            ModelsConfig.fromYaml(value);
          case 'customProviders':
            _validateCustomProviders(value);
          case 'ttsr':
            TtsrConfig.fromYaml(value, sourcePath: label);
          case 'a2a':
            // ${NAME} tokens resolve against the process environment at
            // boot; structural validation passes a null env.
            A2aConfig.fromYaml(value, (_) => null);
          case 'providerTimeouts':
            _validateProviderTimeouts(value);
          case 'skills':
            _validateSkillsSection(value);
          case 'prompts':
            // Deep validation (strict prompt names) lives behind
            // cli_config.dart's strict parser; here the section must be a
            // string-valued map.
            _validateStringMap(value, key);
        }
      }
    } on ConfigException catch (error) {
      errors.add(ConfigDiagnostic(label, '$key: ${error.message}'));
    }
  }
}

void _validateCustomProviders(Object? node) {
  if (node is! YamlList) {
    throw ConfigException('must be a list of provider entries');
  }
  for (final entry in node) {
    CustomProviderEntry.fromYaml(entry);
  }
}

/// Mirrors the strict private parser in `cli_config.dart` (pinned by test).
void _validateProviderTimeouts(Object? node) {
  if (node is! YamlMap) {
    throw ConfigException('must be a map, got: $node');
  }
  for (final entry in node.entries) {
    final key = '${entry.key}';
    if (key != 'connectTimeoutMs' && key != 'streamIdleTimeoutMs') {
      throw ConfigException('unknown "providerTimeouts" key: $key');
    }
    final value = entry.value;
    if (value is! int || value <= 0) {
      throw ConfigException(
        '"providerTimeouts.$key" must be a positive integer (milliseconds)',
      );
    }
  }
}

/// Mirrors the strict private parser in `cli_config.dart` (pinned by test).
void _validateSkillsSection(Object? node) {
  if (node is! YamlMap) {
    throw ConfigException('must be a map, got: $node');
  }
  for (final entry in node.entries) {
    switch ('${entry.key}') {
      case 'access':
        final value = '${entry.value}'.trim();
        if (!{'ask', 'granted', 'denied'}.contains(value)) {
          throw ConfigException(
            'skills.access must be ask, granted or denied, got: $value',
          );
        }
      case 'disableShellExecution':
        if (entry.value is! bool) {
          throw ConfigException(
            'skills.disableShellExecution must be a boolean',
          );
        }
      default:
        throw ConfigException('unknown "skills" key: ${entry.key}');
    }
  }
}

void _validateStringMap(Object? node, String section) {
  if (node is! YamlMap) {
    throw ConfigException('$section must be a map');
  }
  for (final entry in node.entries) {
    if (entry.value is! String) {
      throw ConfigException('$section.${entry.key} must be a string');
    }
  }
}
