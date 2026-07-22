// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'sandbox_builtins.dart';

/// Removes a directory tree from the shell's filesystem; a missing directory
/// is ignored. The path is the verbatim command argument; the closure
/// resolves it against the shell's current directory.
typedef SandboxDirRemover = Future<void> Function(String path);

/// The pip-lite subcommands supported by the sandbox.
enum PipSubcommand { install, uninstall, list, show, help, version }

/// One parsed package requirement: `name`, `name==version`, or the
/// `name-version` shorthand (split at the last dash whose tail starts with
/// a digit, so `python-dateutil` stays a plain name).
final class PipPackageSpec {
  /// Creates a spec for [name], optionally pinned to [version].
  const PipPackageSpec(this.name, [this.version]);

  /// PyPI package name.
  final String name;

  /// Pinned version, or null for the latest release.
  final String? version;

  @override
  String toString() => version == null ? name : '$name==$version';
}

/// A parsed `pip` invocation. [usageError] is non-null when the arguments
/// are invalid; the caller prints it (plus the usage text) and exits 2.
final class PipArgs {
  /// Creates a parse result.
  const PipArgs({
    required this.subcommand,
    this.specs = const [],
    this.usageError,
  });

  /// The requested subcommand.
  final PipSubcommand subcommand;

  /// Validated package specs (empty for `list`/`help`/`version`).
  final List<PipPackageSpec> specs;

  /// Human-readable usage error, when the arguments are invalid.
  final String? usageError;
}

/// Usage text shared by both shells' `pip` implementations.
const String pipUsageText =
    'Usage: pip <command> [args]\n'
    '\n'
    'Commands:\n'
    '  install <pkg>[==<ver>]  Install pure-Python wheels from PyPI\n'
    '  uninstall <pkg>...      Remove installed packages\n'
    '  list                    List installed packages\n'
    '  show <pkg>              Show package metadata\n'
    '\n'
    'Only pure-Python wheels (py3-none-any) are supported; the sandbox\n'
    'python cannot load native extensions.\n';

final RegExp _namePattern = RegExp(
  r'^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$',
);
final RegExp _versionPattern = RegExp(r'^[A-Za-z0-9.!+_*]+$');

/// Parses a pip-lite package spec, or returns null when [raw] is not a
/// valid `name`, `name==version`, or `name-version` requirement.
PipPackageSpec? parsePipSpec(String raw) {
  var name = raw;
  String? version;
  final eq = raw.indexOf('==');
  if (eq > 0) {
    name = raw.substring(0, eq);
    version = raw.substring(eq + 2);
  } else {
    final dash = raw.lastIndexOf('-');
    if (dash > 0 &&
        dash + 1 < raw.length &&
        raw.codeUnitAt(dash + 1) >= 0x30 &&
        raw.codeUnitAt(dash + 1) <= 0x39) {
      name = raw.substring(0, dash);
      version = raw.substring(dash + 1);
    }
  }
  if (!_namePattern.hasMatch(name)) return null;
  if (version != null && !_versionPattern.hasMatch(version)) return null;
  return PipPackageSpec(name, version);
}

/// Parses [args] (everything after `pip`) into a [PipArgs], validating the
/// operand count and package specs for each subcommand.
PipArgs parsePipArgs(List<String> args) {
  if (args.isEmpty) {
    return const PipArgs(subcommand: PipSubcommand.help);
  }
  final first = args.first;
  if (first == '--version' || first == '-V') {
    return const PipArgs(subcommand: PipSubcommand.version);
  }
  if (first == '--help' || first == '-h' || first == 'help') {
    return const PipArgs(subcommand: PipSubcommand.help);
  }
  final subcommand = switch (first) {
    'install' => PipSubcommand.install,
    'uninstall' => PipSubcommand.uninstall,
    'list' => PipSubcommand.list,
    'show' => PipSubcommand.show,
    _ => null,
  };
  if (subcommand == null) {
    return PipArgs(
      subcommand: PipSubcommand.help,
      usageError: 'pip: unknown command "$first"',
    );
  }
  final operands = args
      .sublist(1)
      .where((a) => a != '-y' && a != '--yes')
      .toList();
  for (final operand in operands) {
    if (operand.startsWith('-')) {
      return PipArgs(
        subcommand: subcommand,
        usageError: 'pip: no such option: $operand',
      );
    }
  }
  if (subcommand == PipSubcommand.list) {
    if (operands.isNotEmpty) {
      return const PipArgs(
        subcommand: PipSubcommand.list,
        usageError: 'pip: list takes no arguments',
      );
    }
    return const PipArgs(subcommand: PipSubcommand.list);
  }
  if (operands.isEmpty) {
    return PipArgs(
      subcommand: subcommand,
      usageError: 'pip: $first requires a package name',
    );
  }
  if (subcommand == PipSubcommand.show && operands.length != 1) {
    return const PipArgs(
      subcommand: PipSubcommand.show,
      usageError: 'pip: show takes exactly one package name',
    );
  }
  final specs = <PipPackageSpec>[];
  for (final operand in operands) {
    final spec = parsePipSpec(operand);
    if (spec == null) {
      return PipArgs(
        subcommand: subcommand,
        usageError: "pip: invalid requirement: '$operand'",
      );
    }
    specs.add(spec);
  }
  return PipArgs(subcommand: subcommand, specs: specs);
}

/// A wheel file listed by the PyPI JSON API, with its filename tags parsed.
final class PipWheel {
  /// Creates a wheel entry.
  const PipWheel({
    required this.filename,
    required this.url,
    required this.pythonTag,
    required this.abiTag,
    required this.platformTag,
  });

  /// Wheel filename, e.g. `requests-2.31.0-py3-none-any.whl`.
  final String filename;

  /// Download URL (files.pythonhosted.org).
  final String url;

  /// Python tag (`py3`, `py2.py3`, `cp312`, ...).
  final String pythonTag;

  /// ABI tag (`none` for pure-Python wheels).
  final String abiTag;

  /// Platform tag (`any` for pure-Python wheels).
  final String platformTag;

  /// Whether this wheel is installable by the sandbox python (no native
  /// extensions): `none` ABI on `any` platform.
  bool get isPurePython => abiTag == 'none' && platformTag == 'any';
}

/// Parses [filename] (`{dist}-{version}[-{build}]-{py}-{abi}-{plat}.whl`)
/// into a [PipWheel], or returns null when the name is not a wheel filename.
PipWheel? parseWheelFilename(String filename, String url) {
  if (!filename.endsWith('.whl')) return null;
  final stem = filename.substring(0, filename.length - '.whl'.length);
  final parts = stem.split('-');
  if (parts.length < 5) return null;
  return PipWheel(
    filename: filename,
    url: url,
    pythonTag: parts[parts.length - 3],
    abiTag: parts[parts.length - 2],
    platformTag: parts.last,
  );
}

/// Preference score for pure-Python wheels: `py3` beats `py2.py3` beats
/// `py` beats any other pure tag (e.g. `py39`). Lower is better.
int _pureWheelRank(PipWheel wheel) {
  return switch (wheel.pythonTag) {
    'py3' => 0,
    'py2.py3' => 1,
    'py' => 2,
    _ => 3,
  };
}

/// Result of resolving a spec against the PyPI JSON API: either the chosen
/// [wheel] (plus the resolved [version]) or a user-facing [error] message.
typedef PipResolution = ({PipWheel? wheel, String? version, String? error});

/// Resolves [spec] to the best pure-Python wheel via the PyPI JSON API
/// (`https://pypi.org/pypi/<name>[/<version>]/json`). Binary-only packages
/// produce a clear refusal; network failures surface as an error message.
Future<PipResolution> resolvePipWheel(
  http.Client client,
  PipPackageSpec spec, {
  Duration? timeout,
}) async {
  const pypiBase = 'https://pypi.org/pypi';
  final url = spec.version == null
      ? '$pypiBase/${spec.name}/json'
      : '$pypiBase/${spec.name}/${spec.version}/json';

  final Map<String, dynamic> json;
  try {
    final response = await _get(client, url, timeout);
    if (response.statusCode != 200) {
      return (
        wheel: null,
        version: null,
        error: await _notFoundError(client, spec, pypiBase, timeout),
      );
    }
    json = jsonDecode(response.body) as Map<String, dynamic>;
  } on Object catch (e) {
    return (
      wheel: null,
      version: null,
      error: 'ERROR: Could not reach PyPI: $e\n',
    );
  }

  final info = json['info'] as Map<String, dynamic>? ?? const {};
  final version = (info['version'] as String?) ?? spec.version ?? '';
  final urls = json['urls'] as List<dynamic>? ?? const [];
  final wheels = <PipWheel>[];
  var sawSdist = false;
  for (final entry in urls) {
    final file = entry as Map<String, dynamic>;
    if (file['packagetype'] == 'sdist') {
      sawSdist = true;
      continue;
    }
    if (file['packagetype'] != 'bdist_wheel') continue;
    final wheel = parseWheelFilename(
      file['filename'] as String? ?? '',
      file['url'] as String? ?? '',
    );
    if (wheel != null) wheels.add(wheel);
  }

  final pure = wheels.where((w) => w.isPurePython).toList()
    ..sort((a, b) => _pureWheelRank(a).compareTo(_pureWheelRank(b)));
  if (pure.isEmpty) {
    final found = wheels.isEmpty
        ? (sawSdist ? 'only a source distribution' : 'no files')
        : 'only binary/platform wheels (${wheels.take(3).map((w) => w.filename).join(', ')}'
              '${wheels.length > 3 ? ', ...' : ''})';
    return (
      wheel: null,
      version: null,
      error:
          'ERROR: $spec has no pure-Python wheel; the sandbox python only '
          'supports pure-Python wheels (py3-none-any) — found $found.\n',
    );
  }
  return (wheel: pure.first, version: version, error: null);
}

/// Builds the "Could not find a version" message for a PyPI 404, listing
/// the available versions when the package itself exists.
Future<String> _notFoundError(
  http.Client client,
  PipPackageSpec spec,
  String pypiBase,
  Duration? timeout,
) async {
  var versions = 'none';
  if (spec.version != null) {
    try {
      final response = await _get(
        client,
        '$pypiBase/${spec.name}/json',
        timeout,
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final releases = (json['releases'] as Map<String, dynamic>? ?? const {})
            .keys
            .toList();
        if (releases.isNotEmpty) versions = releases.join(', ');
      }
    } on Object {
      // Fall through with `versions: none`.
    }
  }
  return 'ERROR: Could not find a version that satisfies the requirement '
      '$spec (from versions: $versions)\n';
}

/// GETs [url] following redirects (PyPI wheel URLs live on
/// files.pythonhosted.org). Transport failures propagate to the caller.
Future<http.Response> _get(
  http.Client client,
  String url,
  Duration? timeout,
) async {
  final request = http.Request('GET', Uri.parse(url))..followRedirects = true;
  final streamed = await client
      .send(request)
      .timeout(timeout ?? const Duration(seconds: 30));
  return http.Response.fromStream(streamed);
}

/// pip-lite for the WASI sandbox shell: `pip install`/`uninstall`/`list`/
/// `show` against a site-packages directory the sandbox python imports from.
///
/// Pure Python wheels only: [install] resolves the wheel through the PyPI
/// JSON API (via the injectable [http.Client], so tests use `MockClient`),
/// downloads it in Dart — never through python's own networking — and
/// unzips it into [sitePackagesPath] (`*.dist-info` metadata included, which
/// is what [list]/[show]/[uninstall] read back). Binary/platform wheels are
/// refused with a clear message.
///
/// The web shell does not use this class; it routes `pip` through pyodide's
/// micropip instead (see [runMicropipPip]).
final class SandboxPipBuiltins {
  /// Creates pip-lite over the injected filesystem and HTTP client.
  SandboxPipBuiltins({
    http.Client? httpClient,
    required this.sitePackagesPath,
    required this.writeBinaryFile,
    required this.listDirectory,
    required this.readTextFile,
    required this.removeFile,
    required this.removeDirectory,
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  /// Sandbox-absolute path of the site-packages directory the sandbox
  /// python imports from (`/usr/local/lib/python3.14/site-packages`).
  final String sitePackagesPath;

  /// Injected binary-file writer; see [SandboxBytesWriter].
  final SandboxBytesWriter writeBinaryFile;

  /// Injected directory lister; see [SandboxDirLister].
  final SandboxDirLister listDirectory;

  /// Injected text-file reader; see [SandboxTextReader].
  final SandboxTextReader readTextFile;

  /// Injected file remover; see [SandboxFileRemover].
  final SandboxFileRemover removeFile;

  /// Injected recursive directory remover; see [SandboxDirRemover].
  final SandboxDirRemover removeDirectory;

  static SandboxBuiltinResult _ok(String stdout) => SandboxBuiltinResult(
    stdout: utf8.encode(stdout),
    stderr: const [],
    exitCode: 0,
  );

  static SandboxBuiltinResult _err(String stderr, int exitCode) =>
      SandboxBuiltinResult(
        stdout: const [],
        stderr: utf8.encode(stderr),
        exitCode: exitCode,
      );

  /// Dispatches one `pip` invocation (everything after the command name).
  Future<SandboxBuiltinResult> run(
    List<String> args, {
    Duration? timeout,
  }) async {
    final parsed = parsePipArgs(args);
    final usageError = parsed.usageError;
    if (usageError != null) {
      return _err('$usageError\n$pipUsageText', 2);
    }
    return switch (parsed.subcommand) {
      PipSubcommand.help => _ok(pipUsageText),
      PipSubcommand.version => _ok('pip 24.0 (fah-sandbox pip-lite)\n'),
      PipSubcommand.list => _list(),
      PipSubcommand.show => _show(parsed.specs.single),
      PipSubcommand.install => _install(parsed.specs, timeout),
      PipSubcommand.uninstall => _uninstall(parsed.specs),
    };
  }

  Future<SandboxBuiltinResult> _install(
    List<PipPackageSpec> specs,
    Duration? timeout,
  ) async {
    final installed = <String>[];
    for (final spec in specs) {
      final resolution = await resolvePipWheel(
        _httpClient,
        spec,
        timeout: timeout,
      );
      if (resolution.error != null) return _err(resolution.error!, 1);
      if (resolution.wheel == null) {
        return _err('ERROR: no compatible wheel found for $spec\n', 1);
      }
      final wheel = resolution.wheel!;
      final List<int> bytes;
      try {
        final response = await _get(_httpClient, wheel.url, timeout);
        if (response.statusCode != 200) {
          return _err(
            'ERROR: failed to download ${wheel.filename} '
            '(HTTP ${response.statusCode})\n',
            1,
          );
        }
        bytes = response.bodyBytes;
      } on Object catch (e) {
        return _err('ERROR: failed to download ${wheel.filename}: $e\n', 1);
      }
      final String distInfo;
      try {
        distInfo = await _installWheelBytes(bytes);
      } on Object catch (e) {
        return _err('ERROR: ${wheel.filename} is not a valid wheel: $e\n', 1);
      }
      installed.add(_distNameVersion(distInfo));
    }
    return _ok('Successfully installed ${installed.join(' ')}\n');
  }

  /// Unzips the wheel [bytes] into [sitePackagesPath], skipping path
  /// traversal entries and `*.data/` payloads (scripts/headers the sandbox
  /// cannot use). Returns the installed `*.dist-info` directory name.
  Future<String> _installWheelBytes(List<int> bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    String? distInfo;
    for (final file in archive.files) {
      final name = _safeEntryName(file.name);
      if (name == null) continue;
      final top = name.split('/').first;
      if (top.endsWith('.data')) continue;
      if (!file.isFile) continue;
      if (top.endsWith('.dist-info')) distInfo ??= top;
      await writeBinaryFile(
        '$sitePackagesPath/$name',
        file.content as List<int>,
      );
    }
    if (distInfo == null) {
      throw const FormatException('no .dist-info metadata found');
    }
    return distInfo;
  }

  /// `requests-2.31.0.dist-info` → `requests-2.31.0`.
  String _distNameVersion(String distInfoDir) {
    final stem = distInfoDir.substring(
      0,
      distInfoDir.length - '.dist-info'.length,
    );
    return stem;
  }

  /// Splits a dist-info directory name into (normalized name, version).
  ({String name, String version})? _parseDistInfo(String dirName) {
    if (!dirName.endsWith('.dist-info')) return null;
    final stem = dirName.substring(0, dirName.length - '.dist-info'.length);
    final dash = stem.lastIndexOf('-');
    if (dash <= 0) return null;
    return (
      name: _normalizeName(stem.substring(0, dash)),
      version: stem.substring(dash + 1),
    );
  }

  /// PEP 503 normalization: lowercase, `[-_.]+` collapses to `-`.
  static String _normalizeName(String name) {
    return name.toLowerCase().replaceAll(RegExp(r'[-_.]+'), '-');
  }

  Future<List<({String dirName, String name, String version})>>
  _installedDists() async {
    final entries = await listDirectory(sitePackagesPath) ?? const [];
    final dists = <({String dirName, String name, String version})>[];
    for (final entry in entries) {
      if (!entry.isDirectory) continue;
      final parsed = _parseDistInfo(entry.name);
      if (parsed == null) continue;
      dists.add((
        dirName: entry.name,
        name: parsed.name,
        version: parsed.version,
      ));
    }
    dists.sort((a, b) => a.name.compareTo(b.name));
    return dists;
  }

  Future<SandboxBuiltinResult> _list() async {
    final dists = await _installedDists();
    return _ok(_formatListTable({for (final d in dists) d.name: d.version}));
  }

  Future<SandboxBuiltinResult> _show(PipPackageSpec spec) async {
    final dist = await _findDist(spec.name);
    if (dist == null) {
      return _err('WARNING: Package(s) not found: ${spec.name}\n', 0);
    }
    final metadata = await readTextFile(
      '$sitePackagesPath/${dist.dirName}/METADATA',
    );
    if (metadata == null) {
      return _err('WARNING: Package(s) not found: ${spec.name}\n', 0);
    }
    final fields = <String, String>{};
    final requires = <String>[];
    for (final line in metadata.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx);
      final value = line.substring(idx + 1).trim();
      if (key == 'Requires-Dist') {
        requires.add(value.split(RegExp(r'[ (;]')).first);
      } else {
        fields.putIfAbsent(key, () => value);
      }
    }
    final buffer = StringBuffer();
    for (final key in [
      'Name',
      'Version',
      'Summary',
      'Home-page',
      'Author',
      'License',
    ]) {
      final value = fields[key];
      if (value != null && value.isNotEmpty) buffer.write('$key: $value\n');
    }
    buffer.write('Location: $sitePackagesPath\n');
    if (requires.isNotEmpty) buffer.write('Requires: ${requires.join(', ')}\n');
    return _ok(buffer.toString());
  }

  Future<SandboxBuiltinResult> _uninstall(List<PipPackageSpec> specs) async {
    final output = StringBuffer();
    for (final spec in specs) {
      final dist = await _findDist(spec.name);
      if (dist == null) {
        output.write(
          'WARNING: Skipping ${spec.name} as it is not installed.\n',
        );
        continue;
      }
      // RECORD lists every file the wheel installed (CSV: path,hash,size).
      final record = await readTextFile(
        '$sitePackagesPath/${dist.dirName}/RECORD',
      );
      final topLevelDirs = <String>{};
      if (record != null) {
        for (final line in record.split('\n')) {
          if (line.isEmpty) continue;
          final name = _safeEntryName(line.split(',').first);
          if (name == null) continue;
          final segments = name.split('/');
          if (segments.first == dist.dirName) continue;
          if (segments.length > 1) topLevelDirs.add(segments.first);
          await removeFile('$sitePackagesPath/$name');
        }
      }
      await removeDirectory('$sitePackagesPath/${dist.dirName}');
      for (final dir in topLevelDirs) {
        await removeDirectory('$sitePackagesPath/$dir');
      }
      output.write('Successfully uninstalled ${dist.name}-${dist.version}\n');
    }
    return _ok(output.toString());
  }

  Future<({String dirName, String name, String version})?> _findDist(
    String name,
  ) async {
    final normalized = _normalizeName(name);
    for (final dist in await _installedDists()) {
      if (dist.name == normalized) return dist;
    }
    return null;
  }

  /// Normalizes a zip entry name: rejects absolute paths and `..` traversal,
  /// collapses `.`/empty segments. Returns null when the entry is unsafe.
  static String? _safeEntryName(String raw) {
    final segments = <String>[];
    for (final part in raw.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') return null;
      segments.add(part);
    }
    if (segments.isEmpty) return null;
    return segments.join('/');
  }
}

// ---------------------------------------------------------------------------
// Web path: pip-lite orchestration over pyodide's micropip
// ---------------------------------------------------------------------------

/// Text result of a pip run, shared by the web shell's `pip` builtin.
typedef PipRunResult = ({String stdout, String stderr, int exitCode});

/// Runs one python snippet inside pyodide and returns the captured streams;
/// [error] is the python exception text (null on success).
typedef PipPythonRunner =
    Future<({String stdout, String stderr, String? error})> Function(
      String code,
    );

/// Full pip-lite orchestration for the web shell: parses [args], handles
/// help/version/usage errors without touching the [runner] (so those paths
/// stay offline), and formats the runner's captured output into pip-like
/// results. The runner is only invoked for subcommands that need pyodide.
///
/// micropip itself refuses wheels without a pure-Python build (or a pyodide
/// build); that error text is surfaced verbatim with an added hint.
Future<PipRunResult> runMicropipPip(
  List<String> args,
  PipPythonRunner runner,
) async {
  final parsed = parsePipArgs(args);
  final usageError = parsed.usageError;
  if (usageError != null) {
    return (stdout: '', stderr: '$usageError\n$pipUsageText', exitCode: 2);
  }
  switch (parsed.subcommand) {
    case PipSubcommand.help:
      return (stdout: pipUsageText, stderr: '', exitCode: 0);
    case PipSubcommand.version:
      return (
        stdout: 'pip 24.0 (fah-sandbox pip-lite, micropip)\n',
        stderr: '',
        exitCode: 0,
      );
    case PipSubcommand.list:
    case PipSubcommand.install:
    case PipSubcommand.uninstall:
    case PipSubcommand.show:
      final result = await runner(_micropipCode(parsed));
      return _formatMicropipResult(parsed, result);
  }
}

/// Marker prefixes the generated snippets print for the Dart side to parse.
const _kVer = 'PIPVER:';
const _kList = 'PIPLIST:';
const _kShow = 'PIPSHOW:';
const _kUninstalled = 'PIPUNINSTALLED:';
const _kMissing = 'PIPMISSING:';
const _kNotFound = 'PIP_NOT_FOUND';

/// JSON-encodes [specs] as a python list literal of requirement strings
/// (names/versions are charset-validated, so this embedding is safe).
String _pySpecList(List<PipPackageSpec> specs) {
  return '[${specs.map((s) => '"$s"').join(', ')}]';
}

/// JSON-encodes [names] as a python list literal of bare names.
String _pyNameList(List<String> names) {
  return '[${names.map((n) => '"$n"').join(', ')}]';
}

/// Builds the python snippet executed inside pyodide for [parsed].
String _micropipCode(PipArgs parsed) {
  final specs = parsed.specs;
  final specList = _pySpecList(specs);
  final nameList = _pyNameList([for (final s in specs) s.name]);
  return switch (parsed.subcommand) {
    PipSubcommand.install =>
      'import micropip\n'
          'await micropip.install($specList)\n'
          'import importlib.metadata, json\n'
          'print("$_kVer" + json.dumps({n: importlib.metadata.version(n) '
          'for n in $nameList}))\n',
    PipSubcommand.uninstall =>
      'import importlib.metadata, micropip, json\n'
          'def _fahpip_has(n):\n'
          '    try:\n'
          '        importlib.metadata.version(n)\n'
          '        return True\n'
          '    except importlib.metadata.PackageNotFoundError:\n'
          '        return False\n'
          '_fahpip_names = $nameList\n'
          '_fahpip_missing = [n for n in _fahpip_names if not _fahpip_has(n)]\n'
          'if _fahpip_missing:\n'
          '    print("$_kMissing" + ",".join(_fahpip_missing))\n'
          'else:\n'
          '    _fahpip_ver = {n: importlib.metadata.version(n) '
          'for n in _fahpip_names}\n'
          '    micropip.uninstall(_fahpip_names)\n'
          '    print("$_kUninstalled" + json.dumps(_fahpip_ver))\n',
    PipSubcommand.list =>
      'import micropip, json\n'
          'print("$_kList" + json.dumps({k: str(getattr(v, "version", v)) '
          'for k, v in micropip.list().items()}))\n',
    PipSubcommand.show =>
      'import importlib.metadata as _fahpip_md, json\n'
          'try:\n'
          '    _fahpip_m = _fahpip_md.metadata("${specs.single.name}")\n'
          'except _fahpip_md.PackageNotFoundError:\n'
          '    raise SystemExit("$_kNotFound")\n'
          'print("$_kShow" + json.dumps({k: (_fahpip_m.get(k) or "") for k in '
          '["Name", "Version", "Summary", "Home-page", "Author", "License"]}))\n',
    PipSubcommand.help ||
    PipSubcommand.version => throw StateError('handled locally'),
  };
}

/// Formats one runner result into pip-like output by parsing the marker
/// lines the snippet prints (see [_micropipCode]).
PipRunResult _formatMicropipResult(
  PipArgs parsed,
  ({String stdout, String stderr, String? error}) result,
) {
  final error = result.error;
  if (error != null) {
    if (error.contains(_kNotFound)) {
      return (
        stdout: '',
        stderr: 'WARNING: Package(s) not found: ${parsed.specs.single.name}\n',
        exitCode: 0,
      );
    }
    var text = error.trim();
    if (text.contains('wheel') || text.contains('micropip')) {
      text +=
          '\n(hint: the sandbox python only supports pure-Python wheels; '
          'native extensions cannot be loaded)';
    }
    return (stdout: '', stderr: '$text\n', exitCode: 1);
  }

  final names = [for (final s in parsed.specs) s.name];
  for (final line in result.stdout.split('\n')) {
    if (line.startsWith(_kMissing)) {
      final missing = line.substring(_kMissing.length).split(',');
      return (
        stdout: [
          for (final name in missing)
            'WARNING: Skipping $name as it is not installed.\n',
        ].join(),
        stderr: '',
        exitCode: 0,
      );
    }
    if (line.startsWith(_kUninstalled)) {
      final versions =
          (jsonDecode(line.substring(_kUninstalled.length))
                  as Map<String, dynamic>)
              .cast<String, String>();
      return (
        stdout: [
          for (final name in names)
            'Successfully uninstalled $name-${versions[name]}\n',
        ].join(),
        stderr: '',
        exitCode: 0,
      );
    }
    if (line.startsWith(_kVer)) {
      final versions =
          (jsonDecode(line.substring(_kVer.length)) as Map<String, dynamic>)
              .cast<String, String>();
      return (
        stdout:
            'Successfully installed '
            '${names.map((n) => '$n-${versions[n]}').join(' ')}\n',
        stderr: '',
        exitCode: 0,
      );
    }
    if (line.startsWith(_kList)) {
      final packages =
          (jsonDecode(line.substring(_kList.length)) as Map<String, dynamic>)
              .cast<String, String>();
      return (stdout: _formatListTable(packages), stderr: '', exitCode: 0);
    }
    if (line.startsWith(_kShow)) {
      final fields =
          (jsonDecode(line.substring(_kShow.length)) as Map<String, dynamic>)
              .cast<String, String>();
      final buffer = StringBuffer();
      for (final key in [
        'Name',
        'Version',
        'Summary',
        'Home-page',
        'Author',
        'License',
      ]) {
        final value = fields[key];
        if (value != null && value.isNotEmpty) buffer.write('$key: $value\n');
      }
      return (stdout: buffer.toString(), stderr: '', exitCode: 0);
    }
  }
  // No marker: surface whatever python printed (e.g. micropip's own log).
  return (stdout: result.stdout, stderr: result.stderr, exitCode: 0);
}

/// Renders the `pip list` table from a name → version map.
String _formatListTable(Map<String, String> packages) {
  final names = packages.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  var nameWidth = 'Package'.length;
  var versionWidth = 'Version'.length;
  for (final name in names) {
    if (name.length > nameWidth) nameWidth = name.length;
    if (packages[name]!.length > versionWidth) {
      versionWidth = packages[name]!.length;
    }
  }
  final buffer = StringBuffer()
    ..write('Package'.padRight(nameWidth))
    ..write(' ')
    ..write('Version'.padRight(versionWidth))
    ..write('\n')
    ..write('-' * nameWidth)
    ..write(' ')
    ..write('-' * versionWidth)
    ..write('\n');
  for (final name in names) {
    buffer
      ..write(name.padRight(nameWidth))
      ..write(' ')
      ..write(packages[name]!.padRight(versionWidth))
      ..write('\n');
  }
  return buffer.toString();
}
