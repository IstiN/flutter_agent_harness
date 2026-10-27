// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart' as harness;

import 'package:fa_ui/src/host_config.dart';
import 'package:fa_ui/src/providers/connection.dart' show FaChatModelConfig;
import 'package:fa_ui/src/providers/default_chat_model.dart'
    show FaOnDeviceRoute;
import 'package:fa_ui/src/providers/openrouter_oauth_button.dart';
import 'package:fa_ui/src/providers/provider_editor_page.dart';
import 'package:fa_ui/src/providers/provider_marks.dart';
import 'package:fa_ui/src/providers/provider_preset.dart';
import 'package:fa_ui/src/providers/sso_flows.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';

/// A quick-add template shown in the [AddProviderPresetPickerPage].
///
/// Each template carries enough context (name, description, base URL, icon)
/// to render a tile and route the selection to the right setup flow.
final class AddProviderPreset {
  /// Creates a preset tile.
  const AddProviderPreset({
    required this.key,
    required this.name,
    required this.description,
    required this.icon,
    this.baseUrl,
    this.keyHelpUrl,
  });

  /// Stable identifier for the tile (routing key).
  final String key;

  /// Display name.
  final String name;

  /// One-line description shown under [name].
  final String description;

  /// Leading icon.
  final IconData icon;

  /// Pre-fill base URL for key-based presets; `null` for auth-flow presets
  /// (CodeMie SSO, OpenRouter OAuth) and Custom.
  final String? baseUrl;

  /// A "where do I get the key" page for key-based presets (key console
  /// link shown next to the key field in the editor); null hides the link.
  final String? keyHelpUrl;
}

/// The built-in quick-add presets shown when the user taps "Add provider".
///
/// Host apps may extend or replace this list. Order matters: the most
/// common presets first, `Custom` always last.
const defaultAddProviderPresets = <AddProviderPreset>[
  AddProviderPreset(
    key: 'aiin',
    name: 'AIIN',
    description: 'aiin.by — sign in, key auto-registered',
    icon: Icons.bolt_outlined,
  ),
  AddProviderPreset(
    key: 'openrouter',
    name: 'OpenRouter',
    description: 'OAuth or API key — 300+ models',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://openrouter.ai/api/v1',
  ),
  AddProviderPreset(
    key: 'chatgpt',
    name: 'ChatGPT (Codex)',
    description: 'Account sign-in via OAuth',
    icon: Icons.login,
  ),
  AddProviderPreset(
    key: 'copilot',
    name: 'GitHub Copilot',
    description: 'Account sign-in via device flow',
    icon: Icons.login,
  ),
  AddProviderPreset(
    key: 'codemie',
    name: 'CodeMie',
    description: 'Enterprise SSO sign-in',
    icon: Icons.security_outlined,
  ),
  AddProviderPreset(
    key: 'openai',
    name: 'OpenAI',
    description: 'api.openai.com — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.openai.com/v1',
  ),
  AddProviderPreset(
    key: 'anthropic',
    name: 'Anthropic',
    description: 'api.anthropic.com — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.anthropic.com',
  ),
  AddProviderPreset(
    key: 'google',
    name: 'Google Gemini',
    description: 'Gemini models — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  ),
  AddProviderPreset(
    key: 'dial',
    name: 'DIAL',
    description: 'EPAM DIAL Core — Api key + deployment',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://ai-proxy.lab.epam.com',
  ),
  AddProviderPreset(
    key: 'kimi',
    name: 'Kimi Code',
    description: 'Kimi Code models — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.kimi.com/coding/v1',
    keyHelpUrl: 'https://www.kimi.com/code/console',
  ),
  AddProviderPreset(
    key: 'minimax',
    name: 'MiniMax',
    description: 'MiniMax models — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.minimax.io/v1',
    keyHelpUrl:
        'https://platform.minimax.io/user-center/basic-information/interface-key',
  ),
  AddProviderPreset(
    key: 'zai',
    name: 'Z.AI',
    description: 'GLM models — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://api.z.ai/api/coding/paas/v4',
    keyHelpUrl: 'https://z.ai/manage-apikey/apikey-list',
  ),
  AddProviderPreset(
    key: 'ollama',
    name: 'Ollama Cloud',
    description: 'api.ollama.com — API key',
    icon: Icons.cloud_outlined,
    baseUrl: 'https://ollama.com/v1',
  ),
  AddProviderPreset(
    key: 'custom',
    name: 'Custom',
    description: 'Any OpenAI-compatible endpoint',
    icon: Icons.dns_outlined,
  ),
];

/// Whether a quick-add preset is offered to the user right now.
///
/// Presets backed by the CLI provider catalog ([harness.providerCatalog])
/// follow the catalog's visibility rules: a `visible: false` spec is
/// hidden, and the
/// `FA_PROVIDERS` build/runtime filter ([harness.providerEnabledInBuild])
/// drops filtered-out providers. App-only presets (Kimi, Z.AI, Ollama,
/// Custom — no catalog entry) are always enabled.
///
/// Every surface listing [defaultAddProviderPresets] (the Add-provider
/// picker, onboarding) must filter through this so the CLI and the app
/// never drift apart.
bool addProviderPresetEnabled(AddProviderPreset preset) {
  final spec = harness.providerCatalog[preset.key];
  if (spec == null) return true;
  return spec.visible && harness.providerEnabledInBuild(spec.name);
}

/// Pushes the ONE add-provider flow (issue #975): the host's preset picker
/// when [hostPage] is given (the SSO/OAuth/on-device tile injection point),
/// else the same [AddProviderPresetPickerPage] built from [registry] — so
/// the fallback never offers less than the picker it was opened from
/// ([onDeviceRoutes] ride along).
///
/// Every host-or-fallback ROUTING of the add-provider flow goes through
/// this helper; adding a knob happens once, here. (The canonical
/// Settings → Providers → Add entry is the destination, not a router — it
/// constructs [AddProviderPresetPickerPage] directly by design.)
Future<void> pushAddProviderFlow(
  BuildContext context, {
  WidgetBuilder? hostPage,
  ProviderRegistry? registry,
  harness.ModelsEndpointFetcher? modelsFetcher,
  List<FaOnDeviceRoute> onDeviceRoutes = const [],

  /// The quota service, when the host has one: forwarded to the fallback
  /// picker so its manual adds run the endpoint-confirmation probe
  /// (gh-1378 AC3) the same way the direct constructions do. Host pages
  /// wire their own.
  harness.ProviderQuotaService? quotas,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (routeContext) => hostPage != null
        ? hostPage(routeContext)
        : AddProviderPresetPickerPage(
            registry: registry,
            modelsFetcher: modelsFetcher,
            onDeviceRoutes: onDeviceRoutes,
            quotas: quotas,
          ),
  ),
);

/// The "Add provider" preset picker: a list of quick-add templates that
/// route to the matching setup flow.
///
/// Tapping a key-based preset (OpenRouter, Ollama, Gemini, …) opens the
/// [ProviderEditorPage] pre-filled with the preset's base URL — the user
/// enters their API key and saves. Tapping an SSO/OAuth preset (CodeMie,
/// ChatGPT, Copilot, AIIN) runs the host callback when given, else the
/// default [FaUiSso] flow when [sso] is given; with neither, the tile
/// renders disabled under a tooltip (never silently hidden — issue #1321).
/// Custom opens [ProviderEditorPage] in create mode.
///
/// The page pops when a provider was added (returns `true`) or the user
/// cancels (returns `null`).
class AddProviderPresetPickerPage extends StatelessWidget {
  /// Creates the picker.
  const AddProviderPresetPickerPage({
    super.key,
    this.registry,
    this.presets = defaultAddProviderPresets,
    this.onAiinConnect,
    this.onCodeMieSso,
    this.onChatGptOAuth,
    this.onCopilotConnect,
    this.openRouterOAuthCallbackUrl,
    this.openRouterOAuthCapture,
    this.sso,
    this.onDeviceRoutes = const [],
    this.onOnDeviceConnected,
    this.modelsFetcher,
    this.quotas,
  });

  /// The provider registry: needed so the editor can save the new provider.
  final ProviderRegistry? registry;

  /// The quota service, when the host has one: a manual add on a
  /// quota-marked endpoint runs its endpoint-confirmation probe at add
  /// time (gh-1378 AC3) instead of sitting on a cold cache until the next
  /// pull-to-refresh. Null (previews, tests) skips the probe.
  final harness.ProviderQuotaService? quotas;

  /// `/models` fetch override (tests), forwarded to the provider editor's
  /// model selector.
  final harness.ModelsEndpointFetcher? modelsFetcher;

  /// The preset tiles to show. Defaults to [defaultAddProviderPresets].
  final List<AddProviderPreset> presets;

  /// Called when the user picks the AIIN preset. The host should run its
  /// aiin.by connect flow (browser sign-in + automatic API-key
  /// registration on desktop; WebView in mobile apps). When null, the
  /// default [FaUiSso] flow runs if [sso] is given; otherwise the tile
  /// renders disabled (issue #1321).
  final VoidCallback? onAiinConnect;

  /// Called when the user picks the CodeMie preset. The host should launch
  /// its CodeMie SSO flow (WebView in the app). When null, the default
  /// [FaUiSso] flow runs if [sso] is given; otherwise the tile renders
  /// disabled (issue #1321).
  final VoidCallback? onCodeMieSso;

  /// Called when the user picks the ChatGPT preset. The host should launch
  /// its ChatGPT OAuth flow (local server + browser on macOS, WebView on
  /// iOS). When null, the default [FaUiSso] flow runs if [sso] is given;
  /// otherwise the tile renders disabled (issue #1321).
  final VoidCallback? onChatGptOAuth;

  /// Called when the user picks the Copilot preset. The host should run
  /// the GitHub Copilot connect flow (device-flow sheet + provider setup).
  /// When null, the default [FaUiSso] flow runs if [sso] is given;
  /// otherwise the tile renders disabled (issue #1321).
  final VoidCallback? onCopilotConnect;

  /// `callback_url` for the OpenRouter OAuth flow (forwarded to the editor).
  final String? openRouterOAuthCallbackUrl;

  /// Automatic callback capture for OpenRouter OAuth (forwarded to the
  /// editor).
  final OpenRouterOAuthCaptureCallback? openRouterOAuthCapture;

  /// Ready-made SSO/OAuth/device-flow flows (issue #1321): when given,
  /// the four sign-in tiles no longer require the host callbacks — the
  /// default flows run the CLI's desktop sign-ins and land the provider
  /// in [registry]. An explicit per-provider callback (below) wins over
  /// the default, so a host can adopt the bundle and still customize one
  /// flow. When neither is given, the tile renders DISABLED with a
  /// tooltip (issue #1321 option C — never silently hidden).
  ///
  /// The bundle MUST be built around the same [ProviderRegistry] instance
  /// this page receives — SSO landings go to `sso.registry` while
  /// key-based saves go to [registry], and a split would silently hide
  /// entries from whichever list observes the other store (asserted in
  /// debug mode).
  final FaUiSso? sso;

  /// On-device engine routes (Gemma/WebLLM/…): each renders a tile after
  /// the hosted presets so a never-configured engine is discoverable here
  /// instead of cluttering the Providers list.
  final List<FaOnDeviceRoute> onDeviceRoutes;

  /// A on-device route completed its connect flow (the host connects +
  /// marks the engine configured).
  final ValueChanged<FaChatModelConfig>? onOnDeviceConnected;

  /// Whether a sign-in flow exists for the callback-gated [preset] (a
  /// host callback or the default [sso] bundle).
  bool _hasSsoFlow(AddProviderPreset preset) {
    switch (preset.key) {
      case 'aiin':
        return onAiinConnect != null || sso != null;
      case 'codemie':
        return onCodeMieSso != null || sso != null;
      case 'chatgpt':
        return onChatGptOAuth != null || sso != null;
      case 'copilot':
        return onCopilotConnect != null || sso != null;
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Not a const-ctor assert (instance member access): the bundle MUST be
    // built around the same registry the page received, or SSO landings
    // partition away from the key-based saves.
    assert(
      sso == null || registry == null || identical(sso!.registry, registry),
      'FaUiSso must be built around the same ProviderRegistry the page '
      'receives — SSO landings and key-based saves must land in one store.',
    );
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    // Catalog/build filters hide (intentional — FA_PROVIDERS scims the
    // binary/app down); the callback-gated SSO tiles DISABLE instead
    // (issue #1321 option C: an absent flow is visible and explained,
    // never silent).
    final visiblePresets = <AddProviderPreset>[];
    final catalogHidden = <AddProviderPreset>[];
    for (final preset in presets) {
      if (!addProviderPresetEnabled(preset)) {
        catalogHidden.add(preset);
      } else {
        visiblePresets.add(preset);
      }
    }
    if (catalogHidden.isNotEmpty && kDebugMode) {
      debugPrint(
        'fa_ui: add-provider tiles hidden by the provider catalog / '
        'FA_PROVIDERS filter: '
        '${catalogHidden.map((p) => '${p.key} (${p.name})').join(', ')}',
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsAddProvider)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final preset in visiblePresets)
              _pickerTile(context, theme, strings, preset),
            for (final route in onDeviceRoutes)
              ListTile(
                leading: Icon(
                  Icons.memory_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: Text(route.label),
                subtitle: const Text('Runs on this device — download once'),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onTap: () => _onOnDeviceTap(context, route),
              ),
          ],
        ),
      ),
    );
  }

  /// The one tile for [preset]: enabled with its routing tap when a flow
  /// exists, disabled under a tooltip when the SSO flow is not wired
  /// (issue #1321 option C).
  Widget _pickerTile(
    BuildContext context,
    ThemeData theme,
    FaUiStrings strings,
    AddProviderPreset preset,
  ) {
    final enabled = _hasSsoFlow(preset);
    final tile = ListTile(
      leading: ProviderMark(preset.key, size: 32),
      title: Text(preset.name),
      subtitle: Text(preset.description),
      enabled: enabled,
      trailing: Icon(
        Icons.chevron_right,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      onTap: enabled ? () => _onPresetTap(context, preset) : null,
    );
    if (enabled) return tile;
    return Tooltip(message: strings.ssoFlowUnavailableTooltip, child: tile);
  }

  /// The per-key tap arms (issue #1848 decomposition): the four auth
  /// presets share one SSO arm (each with its host callback + default
  /// flow), Custom pushes the bare editor, every other key is a keyed
  /// preset.
  Map<String, Future<void> Function(BuildContext)> get _tapArms => {
    'aiin': (c) => _tapSsoPreset(c, onAiinConnect, sso?.connectAiin),
    'codemie': (c) => _tapSsoPreset(c, onCodeMieSso, sso?.connectCodeMie),
    'chatgpt': (c) => _tapSsoPreset(c, onChatGptOAuth, sso?.connectChatGpt),
    'copilot': (c) => _tapSsoPreset(c, onCopilotConnect, sso?.connectCopilot),
    'custom': _tapCustom,
  };

  Future<void> _onPresetTap(BuildContext context, AddProviderPreset preset) {
    final arm = _tapArms[preset.key];
    if (arm != null) return arm(context);
    return _tapKeyedPreset(context, preset);
  }

  /// The auth presets (AIIN/CodeMie/ChatGPT/Copilot): the host callback
  /// wins and the picker pops first; otherwise the default [FaUiSso] flow
  /// runs with the picker's own context (the page stays mounted — the flow
  /// pushes its pages on top).
  Future<void> _tapSsoPreset(
    BuildContext context,
    VoidCallback? hostCallback,
    Future<bool> Function(BuildContext)? defaultFlow,
  ) async {
    if (hostCallback != null) {
      Navigator.of(context).pop();
      hostCallback();
      return;
    }
    await _runDefaultSsoFlow(context, defaultFlow!);
  }

  /// The Custom tile: the bare editor in create mode (in-memory registry
  /// when the host gave none). gh-1378 AC3: the manual add runs the same
  /// endpoint confirmation the row's gauge reads — the probe fires now,
  /// not at the next pull-to-refresh. Key-less adds stay probe-less (the
  /// gauge gates on connectivity the same way).
  Future<void> _tapCustom(BuildContext context) async {
    final reg = registry ?? ProviderRegistry.inMemory();
    final landed = await pushProviderEditor(
      context,
      reg,
      title: FaUiStrings.of(context).settingsAddProvider,
      modelsFetcher: modelsFetcher,
      // Not a boarding context (issue #1020 gates onboarding only) —
      // the model stays optional here, as everywhere but onboarding.
      requireModel: false,
    );
    if (landed != null) {
      _confirmQuotaFor(
        landed.baseUrl,
        keyed: (reg.keyFor(landed.id) ?? '').isNotEmpty,
      );
    }
    if (context.mounted) Navigator.of(context).pop(true);
  }

  /// A key-based preset (OpenRouter, Ollama Cloud, Gemini, DIAL, MiniMax,
  /// Kimi Code, Z.AI): every quick-add keeps an editable base URL in the
  /// editor (the user may point DIAL/Ollama/… at another instance); the
  /// [ProviderPreset]-backed ones open in preset mode so the model field
  /// seeds the preset default, the rest open with editable prefills —
  /// several instances of the same provider with custom names are a
  /// first-class use case.
  Future<void> _tapKeyedPreset(
    BuildContext context,
    AddProviderPreset preset,
  ) async {
    final providerPreset = _matchProviderPreset(preset.key);
    final reg = registry;
    // Issue #977, CLI `_entryForBaseUrl` parity: an entry already
    // serving this preset's endpoint prefills the name, so a re-add
    // keeps the (possibly renamed) entry's identity and lands as an
    // update instead of duplicating it.
    final existing = _existingEntryFor(providerPreset, preset);
    final prefill = _keyedPrefill(providerPreset, preset, existing);
    final result = await pushFaPage<ProviderEditorResult>(
      context,
      ProviderEditorPage(
        title: preset.name,
        preset: prefill.preset,
        prefillName: prefill.name,
        prefillBaseUrl: prefill.baseUrl,
        hasSavedKey: _hasResolvedKey(_keyedNamedKey(providerPreset)),
        keyHelpUrl: preset.keyHelpUrl,
        registry: registry,
        openRouterOAuthCallbackUrl: openRouterOAuthCallbackUrl,
        openRouterOAuthCapture: openRouterOAuthCapture,
        modelsFetcher: modelsFetcher,
      ),
    );
    final landed = await _landKeyedResult(reg, result);
    if (landed && context.mounted) Navigator.of(context).pop(true);
  }

  /// The saved entry already serving the preset's endpoint (issue #977,
  /// CLI `_entryForBaseUrl` parity): the re-add lands as an update.
  CustomProvider? _existingEntryFor(
    ProviderPreset providerPreset,
    AddProviderPreset preset,
  ) {
    final targetUrl = providerPreset.baseUrl ?? preset.baseUrl;
    return targetUrl == null ? null : registry?.byBaseUrl(targetUrl);
  }

  /// The keyed editor's prefill: in preset mode (a [ProviderPreset]-
  /// backed quick-add) the preset seeds the model; in editable mode (an
  /// unknown key) the tile's own URL prefills and the name follows the
  /// tile.
  ({ProviderPreset? preset, String? name, String? baseUrl}) _keyedPrefill(
    ProviderPreset providerPreset,
    AddProviderPreset preset,
    CustomProvider? existing,
  ) {
    final editable = providerPreset == ProviderPreset.custom;
    return (
      preset: editable ? null : providerPreset,
      name: existing?.name ?? (editable ? preset.name : null),
      baseUrl: editable ? preset.baseUrl : null,
    );
  }

  /// The preset's named key for the host key chain; null for editable
  /// quick-adds (their key is user-typed, not named).
  String? _keyedNamedKey(ProviderPreset providerPreset) =>
      providerPreset == ProviderPreset.custom
      ? null
      : hostedProviderKeyName(providerPreset);

  /// Whether a preset's named key resolves non-empty through the host's
  /// chain (env / secure store / saved keys).
  static bool _hasResolvedKey(String? namedKey) =>
      namedKey != null && FaUiHost.resolveKey(namedKey, () => '').isNotEmpty;

  /// Editor outcome for a keyed preset: cancels and deletes land nothing
  /// (return false); anything else persists (see [_landNewProvider]) and
  /// returns true.
  Future<bool> _landKeyedResult(
    ProviderRegistry? reg,
    ProviderEditorResult? result,
  ) async {
    if (result == null || result.deleted) return false;
    await _landNewProvider(reg, result);
    return true;
  }

  /// Persists the new provider (a same-endpoint name clash lands as an
  /// update — see [landProviderResult]) and probes the quota.
  Future<void> _landNewProvider(
    ProviderRegistry? reg,
    ProviderEditorResult result,
  ) async {
    if (reg != null) {
      await landProviderResult(reg, result);
    }
    _confirmQuotaFor(result.baseUrl, keyed: result.apiKey.isNotEmpty);
  }

  /// gh-1378 AC3: a manual add on a quota-marked endpoint runs the same
  /// endpoint confirmation the row's gauge reads — at add time, not at
  /// the next pull-to-refresh. Key-less adds stay probe-less (the gauge
  /// gates on connectivity the same way). The catchError mirrors the
  /// service's own `_kick`/`QuotaStore.confirmEndpoint` shape: a failed
  /// probe must never surface as an unhandled async exception on a
  /// fire-and-forget future.
  void _confirmQuotaFor(String baseUrl, {required bool keyed}) {
    final mark = providerMarkKeyForBaseUrl(baseUrl);
    if (quotas == null || !keyed || !quotaMarkIds.contains(mark)) return;
    unawaited(
      quotas!
          .refresh(mark)
          .catchError(
            (_) => const harness.QuotaFetchResult.unknown('no quota source'),
          ),
    );
  }

  /// Runs one of [FaUiSso]'s default flows with the picker's own context
  /// (the page stays mounted — the flow pushes its pages on top), then
  /// pops with the connect outcome.
  Future<void> _runDefaultSsoFlow(
    BuildContext context,
    Future<bool> Function(BuildContext) flow,
  ) async {
    final added = await flow(context);
    if (added && context.mounted) Navigator.of(context).pop(true);
  }

  /// On-device tile: pushes the route's connect page; a completed connect
  /// reports through [onOnDeviceConnected] and pops the picker.
  Future<void> _onOnDeviceTap(
    BuildContext context,
    FaOnDeviceRoute route,
  ) async {
    final config = await pushFaPage<FaChatModelConfig?>(
      context,
      route.pageBuilder(context, (config) async {
        if (context.mounted) Navigator.of(context).pop(config);
      }),
    );
    // Async-gap rule at the call site (the callee re-checks verbatim).
    if (!context.mounted) return;
    _landOnDeviceConfig(context, config);
  }

  /// Lands a completed on-device connect: a real config and a live picker
  /// context report through [onOnDeviceConnected] and pop the picker
  /// (gh-1848 tier-2 split; verbatim guard order).
  void _landOnDeviceConfig(BuildContext context, FaChatModelConfig? config) {
    if (config == null || !context.mounted) return;
    _reportOnDeviceConnected(config);
    Navigator.of(context).pop(true);
  }

  void _reportOnDeviceConnected(FaChatModelConfig config) =>
      onOnDeviceConnected?.call(config);

  /// [AddProviderPreset.key] → the matching [ProviderPreset] for the
  /// editor's preset-mode (preset-seeded model, keep-key note). Falls
  /// back to [custom] (plain editable prefill) for unknown keys. Note the
  /// auth presets ('aiin' et al.) never reach this table — their taps
  /// route to the SSO arm before the keyed one.
  static const _presetByKey = <String, ProviderPreset>{
    'aiin': ProviderPreset.aiin,
    'openrouter': ProviderPreset.openrouter,
    'ollama': ProviderPreset.ollamaCloud,
    'google': ProviderPreset.gemini,
    'dial': ProviderPreset.dial,
    'minimax': ProviderPreset.minimax,
  };

  /// Maps a [AddProviderPreset.key] to the matching [ProviderPreset] for
  /// the editor's preset-mode (preset-seeded model, keep-key note). Falls
  /// back to [custom] (plain editable prefill) for unknown keys.
  static ProviderPreset _matchProviderPreset(String key) =>
      _presetByKey[key] ?? ProviderPreset.custom;
}
