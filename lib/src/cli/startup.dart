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

import '../exceptions.dart';
import '../model_roles/provider_catalog.dart';
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

/// `fa serve --a2a [--port N] [--token T]` interception: the args parser
/// does not know the `--a2a` form, so [args] is scanned for the bare
/// `serve` invocation and the serve-specific flags (and their values) are
/// stripped from the list that reaches [parseCliArgs]. The caller validates
/// that a `serve` invocation actually carries `--a2a` and fails with the
/// usage line before parsing.
({bool serveA2a, List<String> cliArgs}) splitServeA2aArgs(List<String> args) {
  final isServeA2a = args.contains('serve');
  final cliArgs = isServeA2a
      ? [
          for (var i = 0; i < args.length; i++)
            if (args[i] != 'serve' &&
                args[i] != '--a2a' &&
                args[i] != '--port' &&
                args[i] != '--token' &&
                (i == 0 ||
                    (args[i - 1] != '--port' && args[i - 1] != '--token')))
              args[i],
        ]
      : args;
  return (serveA2a: isServeA2a, cliArgs: cliArgs);
}

/// Provider/model restoration. Precedence: an explicit `--provider` flag
/// (full manual control, preconfigs disabled) > the `FA_PROVIDER_*` env
/// declaration ([faProviderPreconfig]) > the saved `provider:` (the
/// persisted /provider switch) > the parsed default. Only kinds the legacy
/// single-model path can build are restored (chatgpt-codex keeps the
/// openai-completions default; its OAuth flow re-establishes on demand).
///
/// The preconfig supplies model/baseUrl too, so the saved restore never
/// leaks through while it is active (--model/--base-url flags still
/// override individual fields). No env-key auto-pick: a bare API key in
/// the environment never activates a provider — the model would be an
/// implicit default, and providers carry none by design. FA_PROVIDER_*
/// stays: it names the model explicitly.
///
/// Returns the effective [CliArgs], the resolved provider kind — the same
/// value, the explicit record field saves the caller a re-derivation — and
/// the `FA_PROVIDER_*` declaration when one is active (the caller needs it
/// for the roles pinning, the key decision and the extra redaction).
({CliArgs args, String provider, EnvProviderPreconfig? faPreconfig})
resolveEffectiveCliArgs(
  CliArgs parsed,
  CliConfig saved, {
  Map<String, String>? env,
}) {
  const restorableKinds = {
    'openai-completions',
    'anthropic',
    'google',
    'dial',
    'minimax',
    'zai',
  };
  final faPreconfig = faProviderPreconfig(parsed, saved, env: env);
  final provider = parsed.providerExplicit
      ? parsed.provider
      : faPreconfig?.spec.kind ??
            (restorableKinds.contains(saved.providerKind)
                ? saved.providerKind
                : parsed.provider);
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
  return (args: effective, provider: provider, faPreconfig: faPreconfig);
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
  Map<String, String>? env,
}) {
  if (parsed.providerExplicit) return null;
  final environ = env ?? Platform.environment;
  return parseEnvProviderPreconfig(
    providerType: environ['FA_PROVIDER_TYPE'],
    providerName: environ['FA_PROVIDER_NAME'],
    providerConfig: environ['FA_PROVIDER_CONFIG'],
    providerConfigBase64: environ['FA_PROVIDER_CONFIG_BASE64'],
    envVarValue: (name) => environ[name],
    takenNames: [for (final entry in saved.customProviders) entry.name],
  );
}

/// The explicit `apiKeyName`s referenced by a roles config (the
/// secure-store preload set; the catalog names are always preloaded).
Set<String> roleKeyNames(ModelRolesConfig rolesConfig) {
  return {
    for (final chain in rolesConfig.roles.values)
      for (final ref in chain)
        if (ref.apiKeyName != null) ref.apiKeyName!,
    for (final override in rolesConfig.pathOverrides)
      for (final chain in override.roles.values)
        for (final ref in chain)
          if (ref.apiKeyName != null) ref.apiKeyName!,
  };
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
            ) ??
            '')
      : _requiredProviderApiKey(
          provider,
          keys,
          baseUrl: baseUrl,
          scopedKeyNames: entryKeyNames,
          env: env,
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
}) {
  final key = optionalProviderApiKey(
    provider,
    keys,
    baseUrl: baseUrl,
    scopedKeyNames: scopedKeyNames,
    env: env,
  );
  if (key == null || key.isEmpty) {
    throw ConfigException(
      'missing API key: set ${apiKeyEnvNames(provider).first} in the '
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
