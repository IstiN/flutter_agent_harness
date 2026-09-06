/// Headless `fa ext <verb>` implementation: list, install, remove, update,
/// audit (enable/disable are REPL-only), plus the startup
/// `.fah/bootstrap.yaml` applier shared by every normal CLI start.
///
/// Payload lines go through [CliIO.write] (stdout when headless), diagnostics
/// and errors through [CliIO.writeln] (stderr when headless), mirroring the
/// trajectory runner. All file access goes through [ExecutionEnv], all
/// network through the injected `package:http` client.
///
/// This library imports `ext_engine_process.dart` (dart:io) for the engine
/// probe, so like that file it is NOT web-safe — the core library never
/// imports it; `bin/fah.dart` does.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../env/execution_env.dart';
import '../exceptions.dart';
import '../js_ext/bundled/bundled_exts.dart';
import '../js_ext/ext_bootstrap_config.dart';
import '../js_ext/ext_catalog.dart';
import '../js_ext/ext_install.dart';
import '../js_ext/ext_manifest.dart';
import '../js_ext/extension_store.dart';
import '../js_ext/jsr_runtime.dart';
import '../js_ext/trust.dart';
import 'agent_cli.dart';
import 'cli_args.dart';
import 'ext_engine_process.dart';

/// One queued install: a label for error lines, the plan thunk, and whether
/// it came from `--bundled` (first-party content, auto-trusted).
typedef _ExtInstallItem = ({
  String label,
  bool bundled,
  Future<ExtInstallPlan> Function() plan,
});

/// Runs one `fa ext <verb>` command and returns the process exit code.
Future<int> runExtCliCommand(
  ExtCliCommand cmd, {
  required CliIO io,
  required ExecutionEnv env,
  required String projectDir,
  required String userDir,
  http.Client? client,
  @internal Duration? networkTimeout,
  @internal Future<String> Function()? engineProbe,
}) async {
  final store = ExtensionStore(
    env: env,
    projectDir: projectDir,
    userDir: userDir,
  );
  final httpClient = client ?? http.Client();
  switch (cmd.verb) {
    case 'list':
      return _extList(
        cmd,
        io,
        store,
        engineProbe ?? QjsProcessRuntime.engineProbe,
      );
    case 'install':
      return _extInstall(cmd, io, env, store, httpClient, networkTimeout);
    case 'remove':
      return _extRemove(cmd, io, store);
    case 'update':
      return _extUpdate(cmd, io, env, store, httpClient, networkTimeout);
    case 'audit':
      return _extAudit(cmd, io, store);
    default: // 'enable' | 'disable' — the parser only admits extVerbs.
      io.writeln(
        'fa ext ${cmd.verb} is REPL-only (run /ext ${cmd.verb} inside fa)',
      );
      return 1;
  }
}

Future<int> _extList(
  ExtCliCommand cmd,
  CliIO io,
  ExtensionStore store,
  Future<String> Function() engineProbe,
) async {
  String engineLine;
  try {
    engineLine = 'engine: ${await engineProbe()}';
  } on ExtEngineUnavailableException catch (error) {
    engineLine = 'engine: unavailable (${error.reason})';
  }
  io.writeln(engineLine);
  final listed = await store.list();
  for (final problem in listed.problems.entries) {
    io.writeln('ext ${problem.key}: ${problem.value}');
  }
  if (cmd.json) {
    for (final ext in listed.extensions) {
      io.write('${jsonEncode(_extListRow(ext))}\n');
    }
    return 0;
  }
  for (final ext in listed.extensions) {
    io.write(_extListLine(ext));
  }
  return 0;
}

String _extListLine(StoredExtension ext) {
  final trust = ext.trust == null ? 'untrusted' : 'trusted';
  final supported = ext.manifest.supportsPlatform(ExtPlatformTag.cli);
  return '${ext.name}  ${ext.scope.name}  '
      '${extKindJson(ext.manifest.kind)} v${ext.manifest.version}  '
      '$trust${supported ? '' : '  unsupported here'}\n';
}

Map<String, Object?> _extListRow(StoredExtension ext) => {
  'name': ext.name,
  'scope': ext.scope.name,
  'kind': extKindJson(ext.manifest.kind),
  'version': ext.manifest.version,
  'supported': ext.manifest.supportsPlatform(ExtPlatformTag.cli),
  'trusted': ext.trust != null,
  if (ext.trust != null) ...{
    'source': ext.trust!.source.name,
    'sourceRef': ext.trust!.sourceRef,
    'sha256': ext.trust!.contentSha256,
  },
};

Future<int> _extInstall(
  ExtCliCommand cmd,
  CliIO io,
  ExecutionEnv env,
  ExtensionStore store,
  http.Client client,
  Duration? networkTimeout,
) async {
  // AC8b: a headless install that grants trust must say so explicitly.
  if (!io.isInteractive &&
      cmd.sources.isNotEmpty &&
      (!cmd.trust || cmd.pin == null)) {
    io.writeln(
      'ext install: refusing to grant trust non-interactively; '
      'pass --trust --pin <sha256> (hash from a trusted channel), or run '
      'interactively to review the trust prompt',
    );
    return 1;
  }
  final prompt = io.isInteractive
      ? (ExtTrustRequest request) => _promptTrust(io, request)
      : null;
  var exitCode = 0;
  for (final item in _installItems(cmd, env, client, networkTimeout)) {
    try {
      final plan = await item.plan();
      // Bundled extensions ship inside this binary — the explicit
      // `fa ext install --bundled` invocation IS the trust decision.
      final outcome = await applyInstall(
        plan,
        store,
        prompt: prompt,
        pinSha256: cmd.pin,
        trustFlag: cmd.trust || item.bundled,
      );
      if (outcome.installed) {
        io.write('installed ${plan.name}\n');
      } else if (outcome.reason == 'up-to-date') {
        io.write('up-to-date ${plan.name}\n');
      } else {
        io.writeln('not installed ${plan.name}: ${outcome.reason}');
        // A headless denial (e.g. a capability change on re-install) is a
        // loud failure; an interactive "no" is a normal outcome unless
        // --strict asks for strictness.
        if (!io.isInteractive || cmd.strict) exitCode = 1;
      }
    } on Object catch (error) {
      io.writeln('install ${item.label} failed: $error');
      exitCode = 1;
    }
  }
  return exitCode;
}

List<_ExtInstallItem> _installItems(
  ExtCliCommand cmd,
  ExecutionEnv env,
  http.Client client,
  Duration? networkTimeout,
) => [
  for (final src in cmd.sources)
    (
      label: src,
      bundled: false,
      plan: () => _planFromSource(src, env, client, networkTimeout),
    ),
  if (cmd.bundled)
    for (final name
        in cmd.bundledName != null
              ? [cmd.bundledName!]
              : kBundledExtensions.keys.toList()
          ..sort())
      (
        label: 'bundled:$name',
        bundled: true,
        plan: () async => planBundledInstall(name),
      ),
];

/// Resolves one install source: `./path` | `/abs` | `path.zip` => local,
/// `gh:owner/repo` | `https://github.com/owner/repo` => github,
/// `catalog:<id>` | bare `<id>` => catalog.
Future<ExtInstallPlan> _planFromSource(
  String src,
  ExecutionEnv env,
  http.Client client,
  Duration? networkTimeout,
) async {
  Future<ExtInstallPlan> plan;
  var network = false;
  if (src.startsWith('gh:')) {
    network = true;
    plan = planGithubInstall(src.substring(3), client);
  } else if (src.startsWith('https://github.com/')) {
    network = true;
    final ref = src.substring('https://github.com/'.length);
    plan = planGithubInstall(
      ref.endsWith('/') ? ref.substring(0, ref.length - 1) : ref,
      client,
    );
  } else if (src.startsWith('catalog:')) {
    network = true;
    plan = planCatalogInstall(
      src.substring(8),
      baseUrl: kExtCatalogBaseUrl,
      client: client,
    );
  } else if (src.startsWith('./') ||
      src.startsWith('/') ||
      (src.endsWith('.zip') && !src.contains('://'))) {
    plan = planLocalInstall(src, env);
  } else {
    network = true;
    plan = planCatalogInstall(src, baseUrl: kExtCatalogBaseUrl, client: client);
  }
  return network && networkTimeout != null
      ? plan.timeout(networkTimeout)
      : plan;
}

Future<bool> _promptTrust(CliIO io, ExtTrustRequest request) async {
  io.writeln(
    'Trust JS extension "${request.name}" from '
    '${request.source.name} (${request.sourceRef})?',
  );
  io.writeln('  sha256: ${request.contentSha256}');
  final summary = request.humanSummary();
  if (summary.isEmpty) {
    io.writeln('  - no elevated capabilities');
  } else {
    for (final line in summary) {
      io.writeln('  - $line');
    }
  }
  io.write('Grant trust? [y/N] ');
  final answer = await io.lines.first;
  final normalized = answer.trim().toLowerCase();
  return normalized == 'y' || normalized == 'yes';
}

Future<int> _extRemove(
  ExtCliCommand cmd,
  CliIO io,
  ExtensionStore store,
) async {
  final name = cmd.name!;
  if (await store.find(name) == null) {
    io.writeln('ext not found: $name');
    return 1;
  }
  await store.remove(name);
  io.write('removed $name\n');
  return 0;
}

Future<int> _extUpdate(
  ExtCliCommand cmd,
  CliIO io,
  ExecutionEnv env,
  ExtensionStore store,
  http.Client client,
  Duration? networkTimeout,
) async {
  late final List<StoredExtension> targets;
  if (cmd.name != null) {
    final one = await store.find(cmd.name!);
    if (one == null) {
      io.writeln('ext not found: ${cmd.name}');
      return 1;
    }
    targets = [one];
  } else {
    targets = (await store.list()).extensions
        .where((ext) => ext.trust != null)
        .toList();
  }
  if (targets.isEmpty) {
    io.writeln('no trusted extensions');
    return 0;
  }
  final prompt = io.isInteractive
      ? (ExtTrustRequest request) => _promptTrust(io, request)
      : null;
  var exitCode = 0;
  for (final ext in targets) {
    final trust = ext.trust;
    if (trust == null) {
      io.writeln('update ${ext.name} failed: untrusted; install it first');
      exitCode = 1;
      continue;
    }
    try {
      final plan = await _replan(ext, trust, env, client, networkTimeout);
      // Capability diff needs a human decision; headless fails loud instead
      // of silently keeping a stale grant (the install is kept on disk).
      final capsChanged = !extCapabilitiesEqual(
        trust.capabilities,
        plan.manifest.capabilities.toJson(),
      );
      if (capsChanged && !io.isInteractive) {
        io.writeln(
          'update ${ext.name} failed: capabilities changed; '
          're-approve interactively: fa ext update ${ext.name}',
        );
        exitCode = 1;
        continue;
      }
      final outcome = await applyInstall(plan, store, prompt: prompt);
      if (outcome.installed) {
        io.write('updated ${ext.name}\n');
      } else if (outcome.reason == 'up-to-date') {
        io.write('up-to-date ${ext.name}\n');
      } else {
        io.writeln('not updated ${ext.name}: ${outcome.reason}');
      }
    } on Object catch (error) {
      io.writeln('update ${ext.name} failed: $error');
      exitCode = 1;
    }
  }
  return exitCode;
}

/// Re-plans an update from the recorded trust provenance: local path re-read,
/// github re-fetch, catalog re-download, bundled re-seed.
Future<ExtInstallPlan> _replan(
  StoredExtension ext,
  TrustRecord trust,
  ExecutionEnv env,
  http.Client client,
  Duration? networkTimeout,
) {
  switch (trust.source) {
    case ExtTrustSource.local:
      return planLocalInstall(trust.sourceRef, env);
    case ExtTrustSource.github:
      final plan = planGithubInstall(trust.sourceRef.split('@').first, client);
      return networkTimeout == null ? plan : plan.timeout(networkTimeout);
    case ExtTrustSource.catalog:
      final plan = planCatalogInstall(
        trust.sourceRef,
        baseUrl: kExtCatalogBaseUrl,
        client: client,
      );
      return networkTimeout == null ? plan : plan.timeout(networkTimeout);
    case ExtTrustSource.bundled:
      return Future<ExtInstallPlan>.value(planBundledInstall(ext.name));
  }
}

Future<int> _extAudit(ExtCliCommand cmd, CliIO io, ExtensionStore store) async {
  late final List<StoredExtension> targets;
  if (cmd.name != null) {
    final one = await store.find(cmd.name!);
    if (one == null) {
      io.writeln('ext not found: ${cmd.name}');
      return 1;
    }
    targets = [one];
  } else {
    targets = (await store.list()).extensions;
  }
  for (final ext in targets) {
    if (cmd.json) {
      io.write('${jsonEncode(_extAuditRow(ext))}\n');
    } else {
      io.write(_extAuditBlock(ext));
    }
  }
  return 0;
}

String _extAuditBlock(StoredExtension ext) {
  final trust = ext.trust;
  if (trust == null) return '${ext.name}: untrusted\n';
  final ref = trust.sourceRef == trust.source.name
      ? ''
      : ' (${trust.sourceRef})';
  return '${ext.name}\n'
      '  source: ${trust.source.name}$ref\n'
      '  sha256: ${trust.contentSha256}\n'
      '  granted: ${trust.grantedAt.toIso8601String()}\n'
      '  capabilities: ${jsonEncode(trust.capabilities)}\n';
}

Map<String, Object?> _extAuditRow(StoredExtension ext) => {
  'name': ext.name,
  'scope': ext.scope.name,
  'trusted': ext.trust != null,
  'source': ext.trust?.source.name,
  'sourceRef': ext.trust?.sourceRef,
  'sha256': ext.trust?.contentSha256,
  'grantedAt': ext.trust?.grantedAt.toIso8601String(),
  'capabilities': ext.trust?.capabilities,
};

/// Applies `.fah/bootstrap.yaml` idempotently for the project scope first,
/// then the user scope (E16: project wins; the loser is reported once).
///
/// Each scope runs at most once per config content: a marker file
/// `<base>/.fah/js-ext/.bootstrap-applied-<sha256-of-yaml>` records the
/// applied config. E15: failures are NAMED lines on the diagnostics channel
/// and never abort the start, unless [strict] rethrows them.
Future<void> applyBootstrapIfPresent({
  required CliIO io,
  required ExecutionEnv env,
  required String projectDir,
  required String userDir,
  http.Client? client,
  bool strict = false,
  @internal Duration? networkTimeout,
}) async {
  final store = ExtensionStore(
    env: env,
    projectDir: projectDir,
    userDir: userDir,
  );
  final httpClient = client ?? http.Client();
  final projectNames = await _applyBootstrapScope(
    io: io,
    env: env,
    store: store,
    client: httpClient,
    scope: ExtStoreScope.project,
    baseDir: projectDir,
    strict: strict,
    networkTimeout: networkTimeout,
    shadowed: null,
  );
  await _applyBootstrapScope(
    io: io,
    env: env,
    store: store,
    client: httpClient,
    scope: ExtStoreScope.user,
    baseDir: userDir,
    strict: strict,
    networkTimeout: networkTimeout,
    shadowed: projectNames,
  );
}

Future<Set<String>> _applyBootstrapScope({
  required CliIO io,
  required ExecutionEnv env,
  required ExtensionStore store,
  required http.Client client,
  required ExtStoreScope scope,
  required String baseDir,
  required bool strict,
  required Duration? networkTimeout,
  required Set<String>? shadowed,
}) async {
  final yamlPath = '$baseDir/.fah/bootstrap.yaml';
  final read = await env.readTextFile(yamlPath);
  if (read.isErr) return const {};
  final text = read.valueOrNull!;
  final marker =
      '$baseDir/.fah/js-ext/'
      '.bootstrap-applied-${crypto.sha256.convert(utf8.encode(text))}';
  if ((await env.exists(marker)).valueOrNull == true) return const {};
  final ExtBootstrapConfig config;
  try {
    config = ExtBootstrapConfig.fromYaml(text);
  } on ConfigException catch (error) {
    if (strict) rethrow;
    io.writeln('ext bootstrap: invalid $yamlPath: ${error.message}');
    return const {};
  }
  final claimed = <String>{};
  final lines = await applyExtBootstrap(
    config: config,
    store: store,
    prompt: io.isInteractive
        ? (ExtTrustRequest request) => _promptTrust(io, request)
        : null,
    strict: strict,
    planner: (entry) async {
      final plan = await _planFromSource(
        entry.source,
        env,
        client,
        networkTimeout,
      );
      if (shadowed != null && shadowed.contains(plan.name)) {
        io.writeln(
          'ext bootstrap: ${entry.source} skipped: project scope already '
          'provides ${plan.name} (E16)',
        );
        return null;
      }
      claimed.add(plan.name);
      return plan;
    },
  );
  for (final line in lines) {
    io.writeln(line);
  }
  await env.writeFile(marker, 'applied\n');
  return claimed;
}
