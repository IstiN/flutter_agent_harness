/// Host-parity contract for compaction wiring (gh-1077): the ONE place
/// where the compaction window, thresholds, summarizer chain, retry knobs
/// and the enable flag are resolved, shared by the CLI ([AgentCli]) and the
/// Flutter app ([AgentService]).
///
/// The divergence this file exists to prevent: the compaction CORE
/// (`AutoCompactor`) is shared, but every config-driven wire used to be
/// resolved per host with subtly different semantics — the app defaulted
/// its window to a constant instead of the provider catalog, never applied
/// the owner cap (`agent.contextWindowCap`), and could silently disagree
/// with the CLI on the rest. Both hosts now compute their wiring through
/// [resolveCompactionHostWiring] (the CLI via
/// [resolveCliCompactionWiring], the app over its own stores), and the
/// parity test (`flutter_app/test/compaction_host_wiring_test.dart`, AC5)
/// asserts both paths resolve semantic equals over the same inputs —
/// drift in either path fails the test.
///
/// What is deliberately NOT here: the compaction algorithm itself (cut
/// points, summary prompt, token estimation — `compaction.dart`, shared
/// and untouched) and per-host smol stream construction (the CLI resolves
/// the full roles chain through [ModelRolesResolver]; the app maps its
/// stores onto the same resolver — see the app's `StoreBackedRolesMap`).
library;

import '../model.dart';
import '../model_roles/model_resolver.dart';
import '../model_roles/roles_config.dart';
import '../providers/models_endpoint.dart' show fallbackContextWindow;
import '../model_roles/provider_catalog.dart' show catalogProvider;
import 'compaction.dart' show CompactionSettings;

/// Compaction is ON by default on every host — the single documented
/// source of truth (gh-1077 fix contract 4). The CLI has no toggle; the
/// app shares this constant so the two hosts cannot silently disagree on
/// whether compaction is even on. A host that ever grows a switch flips
/// THIS default's consumer, not its own local `true`.
const bool compactionEnabledByDefault = true;

/// The summarizer retry ladder both hosts share — the [AutoCompactor]
/// defaults (bounded attempts, linear backoff; overflow-classified failures
/// skip the ladder entirely and route to the next summarizer / the local
/// trim with zero backoff, issue #729). Pinned here so the parity list
/// (window, reserve, summarizer chain, retry policy, enabled) is complete.
const int compactionSummarizerMaxAttempts = 3;

/// First backoff step of the shared summarizer retry ladder (doubled per
/// attempt: 1s, 2s — see [AutoCompactor.baseBackoff]).
const Duration compactionSummarizerBaseBackoff = Duration(seconds: 1);

/// The resolved compaction wiring of ONE host: everything the host needs
/// to gate, size and run a compaction, in the exact shape the parity test
/// compares across hosts.
final class CompactionHostWiring {
  const CompactionHostWiring({
    required this.window,
    required this.conversationWindow,
    required this.settings,
    required this.smolModel,
    required this.enabled,
    this.maxAttempts = compactionSummarizerMaxAttempts,
    this.baseBackoff = compactionSummarizerBaseBackoff,
  });

  /// The EFFECTIVE context window of the main model (owner cap applied via
  /// [effectiveContextWindow]) — the basis the loop's over-window guard
  /// and the ctx meter also use.
  final int window;

  /// What is left of [window] after the host's fixed request overhead
  /// (system prompt / tool instructions). The CLI carries none (0); the
  /// app subtracts its measured on-device overhead. This — not [window] —
  /// is what the compaction thresholds are scaled to and gated on.
  final int conversationWindow;

  /// Compaction thresholds ([CompactionSettings.forWindow] of
  /// [conversationWindow], or the host's explicit override).
  final CompactionSettings settings;

  /// The resolved `smol` summarizer model, when one is configured AND
  /// distinct from the main model (a `smol` equal to the main model is
  /// normalized to `null` — the [AutoCompactor] skips the smol→main
  /// fallback for a same-model pair, so the wiring says so up front).
  /// `null` = the main stream summarizes (main-model fallback as last
  /// resort, gh-1077 fix contract 1).
  final Model? smolModel;

  /// Whether compaction runs at all ([compactionEnabledByDefault] on both
  /// hosts today).
  final bool enabled;

  /// Bounded summarizer retry attempts per pass (shared ladder).
  final int maxAttempts;

  /// First backoff step of the shared ladder (doubled per attempt).
  final Duration baseBackoff;

  /// Whether [other] resolves the same compaction SEMANTICS as this
  /// wiring — the AC5 parity assertion. Models compare by provider/model
  /// identity (Model has no structural equality), settings by their
  /// threshold fields.
  bool sameResolutionAs(CompactionHostWiring other) {
    bool smolSame() {
      final a = smolModel;
      final b = other.smolModel;
      if (a == null || b == null) return a == null && b == null;
      return a.provider == b.provider && a.id == b.id;
    }

    return window == other.window &&
        conversationWindow == other.conversationWindow &&
        settings.enabled == other.settings.enabled &&
        settings.reserveTokens == other.settings.reserveTokens &&
        settings.keepRecentTokens == other.settings.keepRecentTokens &&
        enabled == other.enabled &&
        maxAttempts == other.maxAttempts &&
        baseBackoff == other.baseBackoff &&
        smolSame();
  }
}

/// Resolves one host's compaction wiring from its inputs — the shared
/// semantics both hosts compute through:
///
/// - `window` = [effectiveContextWindow] (owner cap clamps down / raises
///   to the served truth, issues #273/#729);
/// - `conversationWindow` = the effective window minus the host's fixed
///   request overhead (CLI: 0; app: the measured system-prompt / tool
///   instruction tokens);
/// - `settings` = the explicit override when the host plumbed one, else
///   [CompactionSettings.forWindow] of the conversation window;
/// - `smolModel` = the resolved `smol` role, kept only when distinct from
///   the main model;
/// - retry/enabled = the shared defaults ([compactionEnabledByDefault],
///   the pinned summarizer ladder).
CompactionHostWiring resolveCompactionHostWiring({
  required Model mainModel,
  Model? smolModel,
  int? contextWindowCap,
  CompactionSettings? settingsOverride,
  int systemOverheadTokens = 0,
  bool enabled = compactionEnabledByDefault,
}) {
  final window = effectiveContextWindow(
    mainModel.contextWindow,
    contextWindowCap,
  );
  final conversation = window - systemOverheadTokens;
  final distinct =
      smolModel != null &&
      (smolModel.provider != mainModel.provider ||
          smolModel.id != mainModel.id);
  return CompactionHostWiring(
    window: window,
    conversationWindow: conversation > 0 ? conversation : 0,
    settings:
        settingsOverride ??
        CompactionSettings.forWindow(conversation > 0 ? conversation : 0),
    smolModel: distinct ? smolModel : null,
    enabled: enabled,
  );
}

/// The CLI host path (what `AgentCli` resolves): the `smol` summarizer
/// comes from the roles resolver (`roles.smol` chain with the main-model
/// fallback as last resort), the cap from `agent.contextWindowCap`.
///
/// Throws exactly what [ModelRolesResolver.resolveRole] throws (a chain
/// with no usable entry) — the CLI surfaces that as a loud compaction
/// failure, same as before; call it after the `shouldCompact` gate.
CompactionHostWiring resolveCliCompactionWiring({
  required Model mainModel,
  required ModelRolesResolver? rolesResolver,
  required int? contextWindowCap,
  CompactionSettings? settingsOverride,
}) {
  return resolveCompactionHostWiring(
    mainModel: mainModel,
    smolModel: rolesResolver?.resolveRole(smolModelRole)?.model,
    contextWindowCap: contextWindowCap,
    settingsOverride: settingsOverride,
  );
}

/// Resolves the app's context window for a connection (gh-1077 fix
/// contract 2 / AC3): the endpoint-reported or picker-stored value wins,
/// else the provider-catalog window, else the pinned shared fallback
/// ([fallbackContextWindow], 200000 — pi's smallest modern per-model
/// value; E1: this is the documented answer for unknown/custom providers
/// with no catalog entry).
///
/// A stored value equal to the fallback constant means "nothing was
/// known" (both the pickers and the persisted configs use the constant as
/// their default), so it does not suppress the catalog lookup.
int resolveAppContextWindow({String? providerKind, int? storedWindow}) {
  if (storedWindow != null &&
      storedWindow > 0 &&
      storedWindow != fallbackContextWindow) {
    return storedWindow;
  }
  final catalog = providerKind == null
      ? null
      : catalogProvider(providerKind)?.contextWindow;
  return catalog ?? fallbackContextWindow;
}
