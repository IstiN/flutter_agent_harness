/// Pure startup-resolution phases for the `fah` executable
/// (`bin/fah.dart`): the `serve --a2a` argument interception, provider/model
/// restoration from the saved config, the secure-store preload set, the
/// startup API-key decision, and the secret-redactor / web-search secret
/// assembly that `_runApp` composes into a launch.
///
/// The phases live in `lib/` (mirroring `headless_provider_key.dart`) so
/// they unit-test without spawning the CLI; `bin/fah.dart` keeps only the
/// process glue (`_fail`/`exit`, stdio, signals).
///
/// `dart:io` lives here (exported only from `lib/io.dart`) so the agent
/// core stays pure Dart.
library;

import 'dart:io';
import 'package:yaml/yaml.dart';

import '../exceptions.dart';
import '../model_roles/provider_catalog.dart';
import '../model_roles/providers_queue.dart';
import '../model_roles/roles_config.dart';
import '../secrets/secrets_store.dart';
import '../secrets/secure_key_store.dart';
import '../secrets/secret_redactor.dart';
import 'cli_args.dart';
import 'cli_config.dart';
import '../redact/redaction_pipeline.dart';
import 'custom_providers.dart';
import 'env_provider_preconfig.dart';
import 'headless_provider_key.dart';

/// `fa serve [--a2a|--bridge] [--port N] [--token T]` interception: the args
/// parser does not know the serve forms, so [args] is scanned for the bare
/// `serve` invocation and the serve-specific flags (and their values) are
/// stripped from the list that reaches [parseCliArgs]. Exactly one serve
/// form must be selected: [serveA2a]/[serveBridge] say which, and the
/// caller fails with the usage line when a `serve` invocation carries
/// neither, both, or is missing its marker.
({bool serveA2a, bool serveBridge, List<String> cliArgs}) splitServeA2aArgs(
  List<String> args,
) {
  final isServe = args.contains('serve');
  final cliArgs = isServe
      ? [
          for (var i = 0; i < args.length; i++)
            if (args[i] != 'serve' &&
                args[i] != '--a2a' &&
                args[i] != '--bridge' &&
                args[i] != '--port' &&
                args[i] != '--token' &&
                (i == 0 ||
                    (args[i - 1] != '--port' && args[i - 1] != '--token')))
              args[i],
        ]
      : args;
  return (
    serveA2a: isServe && args.contains('--a2a'),
    serveBridge: isServe && args.contains('--bridge'),
    cliArgs: cliArgs,
  );
}

/// The `fa wire-serve` interception result (see [splitWireServeArgs]).
typedef WireServeArgs = ({
  bool wireServe,
  bool stdio,
  int? port,
  String? token,
  List<String> cliArgs,
});

/// `fa wire-serve [--port N] [--stdio] [--token T]` interception (issue
/// #1103): same shape as [splitServeA2aArgs] — the args parser does not
/// know the wire-serve form, so the bare invocation is detected ONLY in
/// the subcommand position (`fa wire-serve ...`; the literal word as any
/// other argument — e.g. a prompt — never intercepts, review #1113 r2)
/// and the wire-serve flags are stripped from the list that reaches
/// [parseCliArgs]. Exactly one transport: `--stdio` and `--port` together
/// are a usage error (the card pins a loud startup failure, never a
/// silent fallback); a bad `--port` value is one too. Repeated flags:
/// last occurrence wins, for both --port and --token (review #1113 r2).
/// Decomposed into one-decision helpers — each stays at cyclomatic 3 or
/// under, the CRAP ratchet floor for covered code.
WireServeArgs splitWireServeArgs(List<String> args) {
  final isWireServe = args.isNotEmpty && args.first == 'wire-serve';
  if (!isWireServe) {
    return (
      wireServe: false,
      stdio: false,
      port: null,
      token: null,
      cliArgs: args,
    );
  }
  final stdio = _hasStandaloneFlag(args, '--stdio');
  final port = _readPort(args);
  final token = _readToken(args);
  _checkTransportExclusivity(stdio, port);
  return (
    wireServe: true,
    stdio: stdio,
    port: port,
    token: token,
    cliArgs: _keepCliArgs(args),
  );
}

/// The card pins exactly one transport per serve process.
void _checkTransportExclusivity(bool stdio, int? port) {
  if (stdio && port != null) {
    throw const FormatException(
      'wire-serve: --stdio and --port are mutually exclusive',
    );
  }
}

/// The last `--port` value in [args] (repeated flags: last wins, same as
/// [_readToken]), or null when the flag is absent. A present-but-
/// unparseable value is a usage error.
int? _readPort(List<String> args) {
  final index = args.lastIndexOf('--port');
  if (index < 0) {
    return null;
  }
  return _parsePortValue(_flagValue(args, index));
}

int _parsePortValue(String? raw) {
  final parsed = int.tryParse(raw ?? '');
  if (parsed == null || parsed < 0) {
    throw const FormatException('wire-serve: --port needs a port number');
  }
  return parsed;
}

/// The last `--token` value in [args] (later flags win, matching a scan),
/// or null when the flag is absent. A present-but-missing value is a
/// usage error.
String? _readToken(List<String> args) {
  final index = args.lastIndexOf('--token');
  if (index < 0) {
    return null;
  }
  final raw = _flagValue(args, index);
  if (raw == null) {
    throw const FormatException('wire-serve: --token needs a value');
  }
  return raw;
}

/// The value following the flag at [flagIndex], or null at the end.
String? _flagValue(List<String> args, int flagIndex) =>
    flagIndex + 1 < args.length ? args[flagIndex + 1] : null;

/// True when [flag] appears at an index that is NOT the verbatim value
/// of a value-taking flag — `fa wire-serve --token --stdio` consumes the
/// word as the token and must not also mean `--stdio` (review #1113 r2).
bool _hasStandaloneFlag(List<String> args, String flag) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] != flag) continue;
    if (_wireServeValueFlags.contains(_previousArg(args, i))) continue;
    return true;
  }
  return false;
}

const _wireServeFlags = {'wire-serve', '--stdio', '--port', '--token'};
const _wireServeValueFlags = {'--port', '--token'};

/// The args that survive wire-serve interception: the subcommand and its
/// flags (and each flag's value) are stripped; everything else reaches
/// [parseCliArgs].
List<String> _keepCliArgs(List<String> args) => _dropFlagValues(
  args,
).where((arg) => !_wireServeFlags.contains(arg)).toList();

/// Drops the value that follows every value-taking flag (`--port N`).
List<String> _dropFlagValues(List<String> args) => [
  for (var i = 0; i < args.length; i++)
    if (!_wireServeValueFlags.contains(_previousArg(args, i))) args[i],
];

String? _previousArg(List<String> args, int index) =>
    index == 0 ? null : args[index - 1];

/// Provider/model restoration. Precedence: an explicit `--provider` flag
/// (full manual control, preconfigs disabled) > the `FA_PROVIDER_*` env
/// declaration ([faProviderPreconfig]) > the saved `provider:` (the
/// persisted /provider switch) > the parsed default.
///
/// The saved kind restores whenever it resolves through the catalog
/// ([resolveCliProviderSpec] — every catalog name AND adapter kind,
/// `chatgpt-codex` included; coverage by construction, issue #760) and
/// restores AS THE RESOLVED SPEC'S KIND: a saved catalog *name* (`openai`,
/// `chatgpt`) resolves to its adapter kind here, because everything
/// downstream (`AgentCliConfig.providerKind` → `providerStreamFunction`)
/// speaks kinds only. A
/// saved id NO version knows must never brick the boot: it is reported
/// back as [unknownSavedProvider] and the parsed default (a known
/// provider) takes over — the executable prints the loud named warning
/// (bad value, file, fallback taken) and keeps booting.
///
/// The preconfig supplies model/baseUrl too, so the saved restore never
/// leaks through while it is active (--model/--base-url flags still
/// override individual fields). No env-key auto-pick: a bare API key in
/// the environment never activates a provider — the model would be an
/// implicit default, and providers carry none by design. FA_PROVIDER_*
/// stays: it names the model explicitly.
/// The environment is injected ([env] is required): the CLI passes
/// `Platform.environment`, tests pass exactly the map they mean —
/// resolution never reads ambient process state.
///
/// Returns the effective [CliArgs], the resolved provider kind — the same
/// value, the explicit record field saves the caller a re-derivation — the
/// `FA_PROVIDER_*` declaration when one is active (the caller needs it
/// for the roles pinning, the key decision and the extra redaction), the
/// saved provider id when it was unrecognizable, and the saved provider id
/// when the persisted provider/baseUrl pair was unservable (endpoint-locked
/// kind, foreign baseUrl — the caller degrades it with a named warning).
/// Both report fields are null otherwise.
({
  CliArgs args,
  String provider,
  EnvProviderPreconfig? faPreconfig,
  String? unknownSavedProvider,
  String? incompatibleSavedEndpoint,
})
resolveEffectiveCliArgs(
  CliArgs parsed,
  CliConfig saved, {
  required Map<String, String> env,
}) {
  final faPreconfig = faProviderPreconfig(parsed, saved, env: env);
  final restore = _judgeSavedRestore(saved);
  final restoredKind = restore.endpointConflict ? null : restore.spec?.kind;
  final provider = _bootProvider(
    parsed: parsed,
    faPreconfig: faPreconfig,
    restoredKind: restoredKind,
  );
  final reports = _savedRestoreReports(
    savedRaw: restore.raw,
    savedSpec: restore.spec,
    endpointConflict: restore.endpointConflict,
    explicitOverride: parsed.providerExplicit || faPreconfig != null,
  );
  final modelId = parsed.model ?? faPreconfig?.modelId ?? saved.modelId;
  final baseUrl = parsed.baseUrl ?? faPreconfig?.baseUrl ?? saved.baseUrl;
  final effective = CliArgs(
    model: modelId,
    provider: provider,
    baseUrl: baseUrl,
    visionModel: parsed.visionModel,
    visionBaseUrl: parsed.visionBaseUrl,
    transcribeModel: parsed.transcribeModel,
    transcribeBaseUrl: parsed.transcribeBaseUrl,
    plugins: parsed.plugins,
    promptTemplateDirs: parsed.promptTemplateDirs,
    mode: parsed.mode ?? saved.mode,
    tools: parsed.tools,
    redact: parsed.redact ?? saved.redact,
    cwd: parsed.cwd,
    sessionRoot: parsed.sessionRoot,
    session: parsed.session,
  );
  return (
    args: effective,
    provider: provider,
    faPreconfig: faPreconfig,
    unknownSavedProvider: reports.unknownSavedProvider,
    incompatibleSavedEndpoint: reports.incompatibleSavedEndpoint,
  );
}

/// The saved-restore judgement (gh-760 review): the saved id trimmed and
/// resolved through the catalog, plus the provider/baseUrl PAIR verdict.
/// A blank saved value is UNSET, not unknown — no version-skew warning for
/// a hand-edit artifact. An endpoint-locked spec ([ProviderSpec
/// .endpointLocked]) over a foreign persisted baseUrl is an unservable
/// PAIR: a partial write (provider overwritten, stale endpoint kept) would
/// otherwise die at the key gate with self-contradictory guidance.
({String raw, ProviderSpec? spec, bool endpointConflict}) _judgeSavedRestore(
  CliConfig saved,
) {
  final raw = saved.providerKind.trim();
  final spec = raw.isEmpty ? null : resolveCliProviderSpec(raw);
  final endpointConflict =
      spec != null &&
      spec.endpointLocked &&
      saved.baseUrl != spec.defaultBaseUrl;
  return (raw: raw, spec: spec, endpointConflict: endpointConflict);
}

/// The boot provider: an explicit `--provider` flag or an `FA_PROVIDER_*`
/// declaration wins; otherwise the saved restore's kind (null when the
/// pair was judged unservable) or the parsed default.
String _bootProvider({
  required CliArgs parsed,
  required EnvProviderPreconfig? faPreconfig,
  required String? restoredKind,
}) {
  if (parsed.providerExplicit) return parsed.provider;
  return faPreconfig?.spec.kind ?? restoredKind ?? parsed.provider;
}

/// The degrade reports for the saved restore: the raw saved id when no
/// version knows it, and the raw saved id when the provider/baseUrl pair
/// was judged unservable. An explicit override (flag or preconfig) silences
/// both — the saved value never took effect, so there is nothing to warn
/// about.
({String? unknownSavedProvider, String? incompatibleSavedEndpoint})
_savedRestoreReports({
  required String savedRaw,
  required ProviderSpec? savedSpec,
  required bool endpointConflict,
  required bool explicitOverride,
}) {
  if (explicitOverride) {
    return (unknownSavedProvider: null, incompatibleSavedEndpoint: null);
  }
  return (
    unknownSavedProvider: savedSpec == null && savedRaw.isNotEmpty
        ? savedRaw
        : null,
    incompatibleSavedEndpoint: endpointConflict ? savedRaw : null,
  );
}

/// The explicit `FA_PROVIDER_*` env preconfig (Docker/headless):
/// `FA_PROVIDER_TYPE` + `FA_PROVIDER_NAME` + `FA_PROVIDER_CONFIG` (a JSON
/// object with required `baseUrl`/`model` and an optional `apiKeyEnvVar`)
/// plus the key env var the config references. Every text input has a
/// `_BASE64` twin (`FA_PROVIDER_CONFIG_BASE64`, `<apiKeyEnvVar>_BASE64`)
/// for platforms that mangle special characters; when both carry the same
/// value the plain one is used. This is an explicit declaration, so it
/// wins over the saved config restore too — a container that declares its
/// provider in env vars runs on it, store or config notwithstanding. An
/// explicit `--provider` flag means full manual control and disables the
/// preconfig entirely (mixing the flag's provider with the env endpoint
/// would be a silent misconfiguration).
///
/// Throws [ConfigException] on a malformed declaration: a container that
/// names its provider wrong must fail loud at boot, not 401 mid-run (the
/// executable maps that to its `fa:` usage failure).
EnvProviderPreconfig? faProviderPreconfig(
  CliArgs parsed,
  CliConfig saved, {
  required Map<String, String> env,
}) {
  if (parsed.providerExplicit) return null;
  return parseEnvProviderPreconfig(
    providerType: env['FA_PROVIDER_TYPE'],
    providerName: env['FA_PROVIDER_NAME'],
    providerConfig: env['FA_PROVIDER_CONFIG'],
    providerConfigBase64: env['FA_PROVIDER_CONFIG_BASE64'],
    envVarValue: (name) => env[name],
    takenNames: [for (final entry in saved.customProviders) entry.name],
  );
}

/// The explicit `apiKeyName`s referenced by a roles config (the
/// secure-store preload set; the catalog names are always preloaded), plus
/// the endpoint-scoped `FA_KEY_<HOST>` slot of every chain entry pinned to
/// a custom endpoint (gh-1000 AC5 — the same source a manual provider
/// switch resolves; the catalog env names describe default endpoints
/// only).
Set<String> roleKeyNames(ModelRolesConfig rolesConfig) {
  final refs = [
    for (final chain in rolesConfig.roles.values) ...chain,
    for (final override in rolesConfig.pathOverrides)
      for (final chain in override.roles.values) ...chain,
  ];
  return {
    for (final ref in refs) ...[
      if (ref.apiKeyName != null) ref.apiKeyName!,
      if (_refNeedsEndpointSlot(ref))
        CustomProviderRegistry.keyNameFor(ref.baseUrl!),
    ],
  };
}

/// Whether [ref] pins a NON-default endpoint — the roles resolver then
/// probes the endpoint-scoped `FA_KEY_<HOST>` slot for it (gh-1000 AC5),
/// so the snapshot must carry that slot. A catalog-default pin resolves
/// through the provider's env-name chain instead and adds no slot
/// (mirroring [ModelRolesResolver._endpointScopedKeyName] exactly: the
/// ref's OWN spec decides); an unknown provider skips in the resolver and
/// consumes no key, so it adds no slot either.
bool _refNeedsEndpointSlot(ModelRef ref) {
  final baseUrl = ref.baseUrl;
  if (baseUrl == null) return false;
  final spec = resolveCliProviderSpec(ref.provider, honorBuildFilter: true);
  // Trailing-slash-normalized — mirrors ModelRolesResolver
  // ._endpointScopedKeyName exactly (the shared sameEndpoint rule).
  return spec != null && !sameEndpoint(baseUrl, spec.defaultBaseUrl);
}

/// Every provider key name the startup snapshot must preload: each catalog
/// provider's env names, the endpoint-scoped `FA_KEY_<HOST>` name for every
/// catalog default endpoint plus the configured endpoint and every saved
/// custom provider's, the two non-catalog media slots, and the explicit
/// `apiKeyName`s referenced by the roles config.
Set<String> secureKeyPreloadNames(CliConfig saved, {required String? baseUrl}) {
  return {
    for (final spec in providerCatalog.values) ...[
      ...spec.apiKeyEnvNames,
      // Endpoint-scoped keys (FA_KEY_<HOST>): catalog defaults.
      CustomProviderRegistry.keyNameFor(spec.defaultBaseUrl),
    ],
    if (baseUrl != null) CustomProviderRegistry.keyNameFor(baseUrl),
    for (final entry in saved.customProviders)
      entry.keyName ?? CustomProviderRegistry.keyNameFor(entry.baseUrl),
    'VISION_API_KEY',
    'TRANSCRIBE_API_KEY',
    if (saved.modelRoles != null) ...roleKeyNames(saved.modelRoles!),
  };
}

/// Fresh-install detection (issue #969): true when NO saved custom provider
/// exists AND no provider key resolves anywhere — no catalog env name (nor
/// its rotation stack) in the environment, and nothing in the preloaded
/// secure-store snapshot. This is the state where the REPL would otherwise
/// boot into the default provider's "no key set" banner noise with no way
/// to configure one except discovering `/provider` first. Every stored
/// snapshot name counts as a resolved key (the host preloads exactly the
/// provider slots: catalog name backups, endpoint-scoped names, media
/// slots, role apiKeyNames) — conservative: anything configured means the
/// user is not fresh and the wizard must not hijack the boot.
///
/// The executable's boot glue (`bin/fah.dart`) ANDs this pure decision with
/// conditions the snapshot cannot see — enumerate there when touching the
/// glue so the two levels stay in sync:
///
/// - not headless (`-p`/positional prompt args and `--output` events mode
///   never get the wizard; the headless hard key gate stays untouched);
/// - no per-folder model restore pending, no explicit `--provider`/`--model`
///   /`--base-url`, no `FA_PROVIDER_*` preconfig, no roles resolution, no
///   provider queue — an explicitly driven boot is not fresh;
/// - the saved default entry is undisturbed: default `providerKind`
///   (`openai-completions`) and default catalog `baseUrl` (a pointed
///   elsewhere entry is a configured provider);
/// - no `--session <name>` resume (a named resumed boot is never fresh)
///   and no pi harness mode (`--pi`/`FA_PI_MODE`/`agent.mode: pi` — the
///   benchmark profile stays deterministic).
bool freshInstallProviderState({
  required Iterable<CustomProviderEntry> customProviders,
  required SecureKeyCache keys,
  Map<String, String>? env,
}) {
  // The snapshot answers first: an O(1) read that covers every store slot,
  // while the env sweep below costs O(env entries × catalog base names).
  if (keys.names.isNotEmpty) return false;
  if (customProviders.isNotEmpty) return false;
  final environment = env ?? Platform.environment;
  final bases = {
    for (final spec in providerCatalog.values) ...spec.apiKeyEnvNames,
  };
  // One sweep: exact base names plus rotation stacks (`NAME_2`, `NAME_3`,
  // …) — a base prefix + `_` + digits only (empty values never count).
  for (final entry in environment.entries) {
    if (entry.value.isEmpty) continue;
    for (final base in bases) {
      if (entry.key == base) return false;
      if (entry.key.length > base.length &&
          entry.key.startsWith(base) &&
          entry.key.codeUnitAt(base.length) == 0x5f &&
          int.tryParse(entry.key.substring(base.length + 1)) != null) {
        return false;
      }
    }
  }
  return true;
}

/// The store-key names the SAVED CONFIG explicitly references (gh-1059):
/// every custom provider entry's own `keyName` plus the roles config's
/// `apiKeyName`s. Env-only setups reference nothing — the boot warning
/// must stay silent for them (a missing env key has its own loud banner).
Set<String> referencedSecureKeyNames(CliConfig saved) {
  return {
    for (final entry in saved.customProviders)
      if (entry.keyName != null) entry.keyName!,
    if (saved.modelRoles != null) ...roleKeyNames(saved.modelRoles!),
  };
}

/// The referenced names whose preload outcome classified [status].
Set<String> _referencedNamesWithStatus(
  Set<String> referencedKeyNames,
  SecureKeyPreloadReport report,
  SecureKeyReadStatus status,
) {
  return referencedKeyNames
      .where(
        (name) =>
            report.outcomes.any((o) => o.name == name && o.status == status),
      )
      .toSet();
}

/// The hint suffix shared by the boot warnings: point at the `[keys]`
/// lines when they were printed, else at the debug switch.
String _bootWarningHint(bool debug, String debugTail) {
  return debug
      ? 'see the [keys] lines above'
      : 'run with --debug-secrets (or FA_DEBUG_KEYS=1) to see $debugTail';
}

/// The store-unavailable boot lines: the debug marker when asked, plus the
/// nothing-resolved warning when the config references store keys (with no
/// backend they resolve 0 too — "never stay invisible").
List<String> _storeUnavailableLines({
  required String label,
  required bool debug,
  required Set<String> referencedKeyNames,
}) {
  return [
    if (debug) '[keys] $label unavailable — no keychain reads attempted',
    if (referencedKeyNames.isNotEmpty)
      'warning: ${referencedKeyNames.length} provider key(s) referenced '
          'by the config (custom providers / roles) resolved NOTHING from '
          'the $label (store unavailable, no reads attempted) — those '
          'providers boot keyless',
  ];
}

/// One `[keys]` line per preload outcome plus the totals summary.
List<String> _debugKeyLines({
  required SecureKeyPreloadReport report,
  required Set<String> referencedKeyNames,
  required String label,
}) {
  return [
    for (final outcome in report.outcomes)
      switch (outcome.status) {
        SecureKeyReadStatus.found => '[keys] ${outcome.name}: found',
        SecureKeyReadStatus.absent => '[keys] ${outcome.name}: absent',
        SecureKeyReadStatus.error =>
          '[keys] ${outcome.name}: error: ${outcome.error ?? 'unknown'}',
      },
    '[keys] ${referencedKeyNames.length} config-referenced, '
        '${report.foundCount} found, ${report.absentCount} absent, '
        '${report.errorCount} errors ($label)',
  ];
}

/// The boot key-snapshot diagnostics (gh-1059): the lines the executable
/// prints after `preload`. With [debug] (`--debug-secrets` / truthy
/// `FA_DEBUG_KEYS`) one `[keys]` line per preload outcome plus a summary —
/// `found` / `absent` / `error: <diagnostic>` — so a degraded keychain is
/// diagnosable instead of silently empty. INDEPENDENT of [debug]:
/// - one warning fires when the store answered but NONE of the
///   config-referenced [referencedKeyNames] resolved — the "every provider
///   boots keyless with no log trail" state — naming the count;
/// - a per-name warning fires whenever any referenced name classified
///   `error` (gh-1059 review: a boot where 7 of 8 keys fail to read but one
///   resolves is just as keyless for those 7) — the store ANSWERED and
///   failed, exactly the state worth naming.
List<String> secureKeyBootDiagnostics({
  required SecureKeyPreloadReport report,
  required Set<String> referencedKeyNames,
  required bool debug,
  String? storeLabel,
}) {
  final lines = <String>[];
  final label = storeLabel ?? 'secure store';
  if (!report.storeAvailable) {
    // Referenced store keys with no backend resolve 0 too — the boot is
    // keyless for them all the same ("never stay invisible").
    return _storeUnavailableLines(
      label: label,
      debug: debug,
      referencedKeyNames: referencedKeyNames,
    );
  }
  if (debug) {
    lines.addAll(
      _debugKeyLines(
        report: report,
        referencedKeyNames: referencedKeyNames,
        label: label,
      ),
    );
  }
  final resolvedReferenced = _referencedNamesWithStatus(
    referencedKeyNames,
    report,
    SecureKeyReadStatus.found,
  );
  if (referencedKeyNames.isNotEmpty && resolvedReferenced.isEmpty) {
    final hint = _bootWarningHint(debug, 'the per-name reads');
    lines.add(
      'warning: ${referencedKeyNames.length} provider key(s) referenced by '
      'the config (custom providers / roles) resolved NOTHING from the '
      '$label — those providers boot keyless; re-enter a key or $hint '
      '(the stored values were not touched)',
    );
  }
  // gh-1059 review: `error` means the store answered and FAILED — the
  // exact state worth naming, even when other referenced keys resolved.
  final erroredReferenced = _referencedNamesWithStatus(
    referencedKeyNames,
    report,
    SecureKeyReadStatus.error,
  ).toList()..sort();
  if (erroredReferenced.isNotEmpty) {
    final hint = _bootWarningHint(debug, 'the errors');
    lines.add(
      'warning: ${erroredReferenced.length} provider key(s) referenced by '
      'the config failed to read from the $label: '
      '${erroredReferenced.join(', ')} — those providers boot keyless; '
      're-enter a key or $hint (the stored values were not touched)',
    );
  }
  return lines;
}

/// Collects the secrets snapshot for the model-roles resolver: every
/// provider catalog env name plus its rotation stack (`NAME`, `NAME_2`,
/// `NAME_3`, ...), plus any base name referenced by an explicit
/// `apiKeyName` in the roles config. The platform secure store backs up
/// base names where the environment has none (env wins; rotation stacks
/// stay env-only — secure storage holds base names only).
Map<String, String> collectRoleSecrets(
  ModelRolesConfig rolesConfig,
  SecureKeyCache keys, {
  Map<String, String>? env,
}) {
  final baseNames = <String>{
    for (final spec in providerCatalog.values) ...spec.apiKeyEnvNames,
    ...roleKeyNames(rolesConfig),
  };
  final secrets = <String, String>{};
  final environment = env ?? Platform.environment;
  for (final base in baseNames) {
    final suffix = RegExp('^${RegExp.escape(base)}_\\d+\$');
    for (final entry in environment.entries) {
      if (entry.key == base || suffix.hasMatch(entry.key)) {
        if (entry.value.isNotEmpty) secrets[entry.key] = entry.value;
      }
    }
    if (!secrets.containsKey(base)) {
      final stored = keys.read(base);
      if (stored != null) secrets[base] = stored;
    }
  }
  return secrets;
}

/// Headless startup API-key resolution: a base URL other than the catalog
/// default (--base-url or config baseUrl) means a user-configured endpoint:
/// local llama.cpp/Ollama/LM Studio servers need no key at all, so the key
/// is optional there (the hosted presets keep requiring one; the config
/// default IS the OpenRouter URL, so compare values, not nullness). Roles
/// mode already tolerates a missing key; the openai-completions adapter
/// omits the Authorization header entirely when the key is empty. The
/// interactive REPL can start without a key: the user can switch providers,
/// models, or base URLs with slash commands before the first run. Headless
/// mode needs a key immediately because it performs a single run and exits.
///
/// Saved custom entries for [baseUrl] carry name-scoped keys
/// (multi-account); they resolve right after the host-scoped slot.
/// [pinnedKeyName] (the restored folder state's saved provider entry,
/// gh-1000) resolves BEFORE both — it names the account the session
/// actually ran on.
///
/// Throws [ConfigException] when the key is required and missing — the
/// executable maps that to its `fa:` usage failure.
String startupApiKey(
  String provider,
  SecureKeyCache keys, {
  required String? baseUrl,
  required List<CustomProviderEntry> customProviders,
  required bool defaultRoleResolved,
  required bool interactive,
  Map<String, String>? env,
  String? pinnedKeyName,
}) {
  // A base URL other than the catalog default (--base-url or config
  // baseUrl) means a user-configured endpoint: local servers need no key.
  final customEndpoint =
      provider == 'openai-completions' &&
      baseUrl != providerCatalog['openrouter']!.defaultBaseUrl;
  // Saved custom entries for this endpoint carry name-scoped keys
  // (multi-account); they resolve right after the host-scoped slot.
  final entryKeyNames = [
    for (final entry in customProviders)
      if (entry.baseUrl == baseUrl && entry.keyName != null) entry.keyName!,
  ];
  final key = defaultRoleResolved || customEndpoint || interactive
      ? (optionalProviderApiKey(
              provider,
              keys,
              baseUrl: baseUrl,
              scopedKeyNames: entryKeyNames,
              env: env,
              pinnedKeyName: pinnedKeyName,
            ) ??
            '')
      : _requiredProviderApiKey(
          provider,
          keys,
          baseUrl: baseUrl,
          scopedKeyNames: entryKeyNames,
          env: env,
          pinnedKeyName: pinnedKeyName,
        );
  return key;
}

/// The required variant of [optionalProviderApiKey]: identical resolution,
/// but a missing key is a hard startup failure (headless mode performs one
/// run and exits — a silent empty key would surface as a provider 401).
String _requiredProviderApiKey(
  String provider,
  SecureKeyCache keys, {
  String? baseUrl,
  Iterable<String>? scopedKeyNames,
  Map<String, String>? env,
  String? pinnedKeyName,
}) {
  final key = optionalProviderApiKey(
    provider,
    keys,
    baseUrl: baseUrl,
    scopedKeyNames: scopedKeyNames,
    env: env,
    pinnedKeyName: pinnedKeyName,
  );
  if (key == null || key.isEmpty) {
    throw ConfigException(
      pinnedKeyName != null
          // A RESTORED pin: the catalog env name describes the DEFAULT
          // endpoint — wrong-slot guidance (gh-1000 AC2, round-3 review).
          // Name the pinned slot the restore actually probed.
          ? 'missing API key for the restored provider: '
                'set it with /key set $pinnedKeyName <value>'
          : 'missing API key: set ${apiKeyEnvNames(provider).first} in the '
                'environment',
    );
  }
  return key;
}

/// Assembles the startup [SecretRedactor]: the API keys this CLI knows
/// about (every catalog provider's env names, the web-search slots) are
/// masked from tool results and the provider context so they cannot leak
/// into the LLM conversation or the session files. The rotation stacks
/// collected for the roles resolver and the values preloaded from the
/// platform secure store (keychain values must never reach the transcript
/// either) are redacted too. The spawned shell already inherits the process
/// environment, so no env injection is needed here.
SecretRedactor buildSecretRedactor({
  Map<String, String> roleSecrets = const {},
  SecureKeyCache? keys,
  Map<String, String>? env,
  RedactionPipeline? pipeline,
}) {
  final redactor = SecretRedactor();
  // Every secret this function registers into the legacy exact-value
  // redactor ALSO feeds the layered pipeline's registered layer, so both
  // masking systems stay in sync (issue #24 stage 3).
  void registerBoth(String name, String value) {
    redactor.register(name, value);
    pipeline?.registerSecret(value);
  }

  final environment = env ?? Platform.environment;
  for (final name in [
    for (final spec in providerCatalog.values) ...spec.apiKeyEnvNames,
    'BRAVE_API_KEY',
    'TAVILY_API_KEY',
  ]) {
    final value = environment[name];
    if (value != null) registerBoth(name, value);
  }
  for (final entry in roleSecrets.entries) {
    registerBoth(entry.key, entry.value);
  }
  if (keys != null) {
    for (final name in keys.names) {
      final value = keys.read(name);
      if (value != null) registerBoth(name, value);
    }
  }
  return redactor;
}

/// Assembles the layered [RedactionPipeline] (issue #24) from the `redact:`
/// config section and this process's well-known secrets. Returns `null`
/// when the section disables redaction (`enabled: false`) so the hooks
/// never attach. Secret registration happens through
/// [buildSecretRedactor]'s `pipeline` parameter — call that first with this
/// pipeline, or register later via [RedactionPipeline.registerSecret].
RedactionPipeline? buildRedactionPipeline(RedactionConfig? config) {
  if (config != null && !config.enabled) return null;
  return RedactionPipeline(
    registeredSecrets: const [],
    config: config ?? const RedactionConfig(),
  );
}

/// Web search works out of the box via keyless DuckDuckGo; keyed providers
/// (Brave, Tavily) join the chain when their API key is in the environment.
InMemorySecretsStore webSearchSecrets({Map<String, String>? env}) {
  final environment = env ?? Platform.environment;
  return InMemorySecretsStore({
    for (final name in const ['BRAVE_API_KEY', 'TAVILY_API_KEY'])
      if (environment[name] case final value? when value.isNotEmpty)
        name: value,
  });
}

/// `'hub'` ships default-on. A `.fah/packages.yaml` entry enables a plugin
/// with a truthy value (`inspect_image:`/`hub: {url: …}`) and opts it OUT
/// with a falsy one (`hub: false`, `hub:`) — so only the keys with truthy
/// values join the enabled set.
Set<String> resolveEnabledPlugins(
  List<String> argPlugins,
  Map<String, dynamic> config,
) {
  final enabled = <String>{'hub', ...argPlugins};
  for (final entry in config.entries) {
    if (entry.value == null || entry.value == false) {
      enabled.remove(entry.key);
    } else {
      enabled.add(entry.key);
    }
  }
  return enabled;
}

/// Resolves the FA_PROVIDERS_QUEUE scope chain at boot: the env var, the
/// project `.fah/config.yaml` `providersQueue:` section, the user
/// `~/.fah/config.yaml` one. Absent files/sections are not present; a
/// present-but-invalid section throws [ConfigException] naming the file
/// (strict, like every other config section).
ProviderQueueResolution resolveProviderQueueAtBoot({
  required String projectDir,
  required String homeDir,
  Map<String, String>? env,
}) {
  final environment = env ?? Platform.environment;
  final envText = environment['FA_PROVIDERS_QUEUE'];
  final inputs = <ProviderQueueScopeInput>[
    ProviderQueueScopeInput(
      scope: ProviderQueueScope.env,
      isPresent: envText != null && envText.trim().isNotEmpty,
      parse: envText == null || envText.trim().isEmpty
          ? null
          : parseProviderQueueEnv(envText),
    ),
    ...[
      for (final (scope, path) in [
        (ProviderQueueScope.project, '$projectDir/.fah/config.yaml'),
        (ProviderQueueScope.user, '$homeDir/.fah/config.yaml'),
      ])
        ?_queueScopeFromFile(scope, path),
    ],
  ];
  return resolveProviderQueueScopes(inputs);
}

ProviderQueueScopeInput? _queueScopeFromFile(
  ProviderQueueScope scope,
  String path,
) {
  final file = File(path);
  if (!file.existsSync()) return null;
  String body;
  try {
    body = file.readAsStringSync();
  } on Object {
    return null;
  }
  final Object? doc;
  try {
    doc = loadYaml(body);
  } on Object catch (error) {
    throw ConfigException('$path: ${error.toString()}');
  }
  if (doc is! YamlMap) return null;
  final node = doc['providersQueue'];
  if (node == null) return null;
  return ProviderQueueScopeInput(
    scope: scope,
    isPresent: true,
    parse: parseProviderQueueYaml(node, source: path),
  );
}

/// Collects the secrets snapshot for the queue: each entry's `apiKeyEnv`
/// resolves from the environment, else the secure store (env wins — the
/// same precedence as the roles snapshot).
Map<String, String> collectQueueSecrets(
  List<ProviderQueueEntry> entries,
  SecureKeyCache keys, {
  Map<String, String>? env,
}) {
  final environment = env ?? Platform.environment;
  final secrets = <String, String>{};
  for (final entry in entries) {
    final name = entry.apiKeyEnv;
    if (name == null || secrets.containsKey(name)) continue;
    final fromEnv = environment[name];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      secrets[name] = fromEnv;
      continue;
    }
    final stored = keys.read(name);
    if (stored != null) secrets[name] = stored;
  }
  return secrets;
}
