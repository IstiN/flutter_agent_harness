/// The omp status bar engine (issue #805, story S2 of #802): a pure-Dart
/// renderer that ports oh-my-pi's status line — the 27-segment registry,
/// the 7 presets, the separator styles, the elastic truncation ladder and
/// the context gauge — onto fa's data.
///
/// The contract with the host (invariant from the umbrella card):
///
/// - The host builds an immutable [StatusLineSnapshot] per frame tick
///   (usage, ctx, cost, cwd, session, git, agents, elapsed). The TUI
///   layer performs ZERO provider fetches and ZERO subprocess calls —
///   git and PR data arrive host-side (the git watcher seam),
///   usage/cost via the existing provider events. [TuiStatusLine.render]
///   reads the snapshot and nothing else: width/layout math runs on raw
///   strings (rule #279 E1), colors flow through [FaThemeController]
///   emitters at write time.
/// - Colors map through [kStatusLineRoles], the statusLine role TABLE:
///   today it consumes the EXISTING [TuiTheme] roles. S1's token merge
///   (#804) adds the dedicated `statusLine*` roles; that merge only
///   re-points this one table — no renderer names a color directly.
/// - The bar is render-only here: attaching it as the composer's bottom
///   chrome (and the `tui.classic: true` kill switch that would revert
///   to the legacy `_statusLine()` footer byte-identically) is S3's
///   story (#806).
///
/// Segment ids, preset shapes, separator glyphs and the truncation
/// ladder port omp's `packages/tui/src/status-line/{schema,presets,
/// separators,segments,component}.ts` at the pinned commit `df624f5`.
library;

import 'dart:collection' show UnmodifiableMapView;

// The vendored dart_tui exports no Style surface (issue #613) — same
// direct-src import tui_theme.dart uses.
// ignore: implementation_imports
import 'package:dart_tui/src/bubbles/style.dart' show RgbColor, Style;
import 'package:yaml/yaml.dart';

import '../exceptions.dart';
import '../trajectory/formatters.dart' show formatTokens;
import 'tui_text_width.dart';
import 'tui_theme.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Snapshot — the host-built data contract
// ═══════════════════════════════════════════════════════════════════════════

/// One git working-tree state, resolved host-side (the git watcher seam:
/// `git status --porcelain` through the bash seam, TTL-cached). A null
/// branch with every count 0 (or a null [StatusLineGit]) hides the git
/// segment — outside a repo, or a failed probe. A detached HEAD arrives
/// as a short sha in [branch]. Never crashes the bar.
final class StatusLineGit {
  final String? branch;

  /// Staged file count (`+N`).
  final int staged;

  /// Unstaged file count (`*N`).
  final int unstaged;

  /// Untracked file count (`?N`).
  final int untracked;

  const StatusLineGit({
    this.branch,
    this.staged = 0,
    this.unstaged = 0,
    this.untracked = 0,
  });

  /// Whether any working-tree change is visible.
  bool get isDirty => staged > 0 || unstaged > 0 || untracked > 0;
}

/// Everything one status-bar frame renders from, built entirely host-side
/// (see the library docs: zero fetches, zero subprocesses from here down).
/// Fields the host cannot supply stay null and their segments hide — a
/// hidden segment is data absence, never a fallback string.
final class StatusLineSnapshot {
  /// Working directory for the `path` segment.
  final String cwd;

  /// Home directory root, `~`-abbreviated by the `path` segment.
  final String? homeDir;

  /// Workspace root the `path` segment strips when
  /// [StatusLineSegmentOptions.stripWorkPrefix] is on.
  final String? workRoot;

  /// Active model id/name; `null` hides the `model` segment.
  final String? modelName;

  /// Thinking-level suffix for `model` (rendered only when
  /// [StatusLineSegmentOptions.showThinkingLevel] is on).
  final String? thinkingLevel;

  /// Approval mode label for `mode` (`yolo`, `write`, …).
  final String? approvalMode;

  /// Agent load mode label for `mode` (`omp`, `pi`, …; `default` renders
  /// as nothing — it is the absence of a special mode).
  final String? agentLoadMode;

  /// Git working-tree state; `null` or a branchless clean state hides git.
  final StatusLineGit? git;

  /// Host-resolved open PR for the current branch (`#123`); `null` hides
  /// `pr` (no tool, unauthed, other forge — the host owns that policy).
  final String? pr;

  /// Live context estimate: provider-reported usage plus the trailing
  /// in-flight estimate (what the NEXT request carries).
  final int contextTokens;

  /// Effective context window in tokens; `0` = unknown (the `context_pct`
  /// segment then renders `used/?` and the gauge renders without labels).
  final int contextWindow;

  /// Provider usage counters (cumulative session totals).
  final int tokensIn;
  final int tokensOut;
  final int cacheRead;
  final int cacheWrite;

  /// Live output rate for `token_rate` (tok/s); hidden when null/zero.
  final double? tokensPerSecond;

  /// Running session cost in USD; `null` = unpriced model → the `cost`
  /// segment hides (E2: never `$0.00` for an unknown price).
  final double? costUsd;

  /// Session display name; `null` hides `session_name`.
  final String? sessionName;

  /// Session id (first 8 chars render); `null` renders the `new` fallback.
  final String? sessionId;

  /// Live background subagent count; hidden when zero.
  final int subagents;

  /// Active-processing time for `time_spent` and the streaming spinner
  /// cadence (idle wall clock excluded).
  final Duration elapsed;

  /// Wall clock for the `time` segment. Injected (never read from the
  /// system here) so renders stay pure and testable on a virtual clock.
  final DateTime? now;

  /// Machine hostname; `null` hides `hostname`.
  final String? hostname;

  /// Whether the agent is idle (vs streaming/working): idle dims the bar
  /// and drives the `pi` brand fade toward its dim endpoint.
  final bool idle;

  /// Milliseconds since the last idle↔working flip; `null` = no flip
  /// observed (the brand mark sits at its endpoint). Drives the 450 ms
  /// brand fade (see [statusLineBrandFadeT]).
  final int? idleChangedAgoMs;

  const StatusLineSnapshot({
    required this.cwd,
    this.homeDir,
    this.workRoot,
    this.modelName,
    this.thinkingLevel,
    this.approvalMode,
    this.agentLoadMode,
    this.git,
    this.pr,
    this.contextTokens = 0,
    this.contextWindow = 0,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.tokensPerSecond,
    this.costUsd,
    this.sessionName,
    this.sessionId,
    this.subagents = 0,
    this.elapsed = Duration.zero,
    this.now,
    this.hostname,
    this.idle = true,
    this.idleChangedAgoMs,
  });

  /// Live context pressure as a percent (0–100+); `null` when the window
  /// is unknown. Derived, never carried: one source of truth.
  double? get contextPercent =>
      contextWindow > 0 ? contextTokens / contextWindow * 100 : null;
}

// ═══════════════════════════════════════════════════════════════════════════
// Roles — the statusLine role table (the S1 seam)
// ═══════════════════════════════════════════════════════════════════════════

/// Every status-line surface that takes a color, keyed for [kStatusLineRoles].
enum StatusLineRoleKey {
  brandA,
  brandB,
  model,
  mode,
  path,
  gitClean,
  gitDirty,
  gitStaged,
  gitUntracked,
  pr,
  subagents,
  spend,
  output,
  context,
  time,
  name,
  dim,
  warn,
  error,
  separator,
  gaugeUsed,
  gaugeUnused,

  /// The band composer's fill (#806): the composer-top-band background
  /// the S3 writer paints behind the rendered spans. Additive key — the
  /// S1 token merge re-points the lambda, never removes the key.
  bandBg,
}

/// The statusLine role TABLE (issue #805 seam): maps each role key onto an
/// EXISTING [TuiTheme] role. S1's token merge (#804) re-points these
/// lambdas at the dedicated `statusLine*` roles — the only place that
/// changes; every renderer paints through this table, never a raw color.
/// Unmodifiable: a stray write must not corrupt every later frame (the
/// S1 token merge re-points entries here, in code, not at runtime).
final Map<StatusLineRoleKey, Style Function(TuiTheme theme)> kStatusLineRoles =
    UnmodifiableMapView(<StatusLineRoleKey, Style Function(TuiTheme theme)>{
      StatusLineRoleKey.brandA: (t) => t.accent,
      StatusLineRoleKey.brandB: (t) => t.accent2,
      StatusLineRoleKey.model: (t) => t.toolTitle,
      StatusLineRoleKey.mode: (t) => t.muted,
      StatusLineRoleKey.path: (t) => t.focusBorder,
      StatusLineRoleKey.gitClean: (t) => t.success,
      StatusLineRoleKey.gitDirty: (t) => t.warning,
      StatusLineRoleKey.gitStaged: (t) => t.success,
      StatusLineRoleKey.gitUntracked: (t) => t.focusBorder,
      StatusLineRoleKey.pr: (t) => t.accent,
      StatusLineRoleKey.subagents: (t) => t.accent2,
      StatusLineRoleKey.spend: (t) => t.accent2Soft,
      StatusLineRoleKey.output: (t) => t.toolOutput,
      StatusLineRoleKey.context: (t) => t.accent2Soft,
      StatusLineRoleKey.time: (t) => t.muted,
      StatusLineRoleKey.name: (t) => t.muted,
      StatusLineRoleKey.dim: (t) => t.muted,
      StatusLineRoleKey.warn: (t) => t.warning,
      StatusLineRoleKey.error: (t) => t.error,
      StatusLineRoleKey.separator: (t) => t.borderMuted,
      StatusLineRoleKey.gaugeUsed: (t) =>
          Style(foregroundRgb: t.focusBorder.foregroundRgb),
      StatusLineRoleKey.gaugeUnused: (t) => t.border,

      // The band fill (#806): the nearest existing background tint (the
      // composer-adjacent user-message band). S1's statusLine* tokens
      // re-point this one lambda — the band writer never names a color.
      StatusLineRoleKey.bandBg: (t) =>
          Style(backgroundRgb: t.userMessageBg.backgroundRgb),
    });

// ═══════════════════════════════════════════════════════════════════════════
// Segment options + presets (verbatim shapes from omp presets.ts)
// ═══════════════════════════════════════════════════════════════════════════

/// Per-segment render options (`segmentOptions:`). Fields the user did
/// not mention stay `null`; the omp defaults resolve through the
/// accessors ([showThinkingLevel], [maxLength], …) and [mergedOver]
/// merges a user partial over a preset base.
final class StatusLineSegmentOptions {
  final bool? modelShowThinkingLevel;
  final bool? pathAbbreviate;
  final int? pathMaxLength;
  final bool? pathStripWorkPrefix;
  final bool? gitShowBranch;
  final bool? gitShowStaged;
  final bool? gitShowUnstaged;
  final bool? gitShowUntracked;
  final bool? time24h;
  final bool? timeShowSeconds;

  const StatusLineSegmentOptions({
    this.modelShowThinkingLevel,
    this.pathAbbreviate,
    this.pathMaxLength,
    this.pathStripWorkPrefix,
    this.gitShowBranch,
    this.gitShowStaged,
    this.gitShowUnstaged,
    this.gitShowUntracked,
    this.time24h,
    this.timeShowSeconds,
  });

  /// omp defaults (the `!== false` readings — on unless switched off).
  bool get showThinkingLevel => modelShowThinkingLevel ?? true;
  bool get abbreviate => pathAbbreviate ?? true;
  int get maxLength => pathMaxLength ?? 40;
  bool get stripWorkPrefix => pathStripWorkPrefix ?? true;
  bool get showBranch => gitShowBranch ?? true;
  bool get showStaged => gitShowStaged ?? true;
  bool get showUnstaged => gitShowUnstaged ?? true;
  bool get showUntracked => gitShowUntracked ?? true;
  bool get clock24h => time24h ?? true;
  bool get showSeconds => timeShowSeconds ?? false;

  /// Field-wise merge: the receiver's mentioned fields win, unmentioned
  /// ones fall back to [base] (the preset's partial).
  StatusLineSegmentOptions mergedOver(StatusLineSegmentOptions base) =>
      StatusLineSegmentOptions(
        modelShowThinkingLevel:
            modelShowThinkingLevel ?? base.modelShowThinkingLevel,
        pathAbbreviate: pathAbbreviate ?? base.pathAbbreviate,
        pathMaxLength: pathMaxLength ?? base.pathMaxLength,
        pathStripWorkPrefix: pathStripWorkPrefix ?? base.pathStripWorkPrefix,
        gitShowBranch: gitShowBranch ?? base.gitShowBranch,
        gitShowStaged: gitShowStaged ?? base.gitShowStaged,
        gitShowUnstaged: gitShowUnstaged ?? base.gitShowUnstaged,
        gitShowUntracked: gitShowUntracked ?? base.gitShowUntracked,
        time24h: time24h ?? base.time24h,
        timeShowSeconds: timeShowSeconds ?? base.timeShowSeconds,
      );

  /// A copy with [pathMaxLength] replaced — the truncation ladder's
  /// path-shrink re-render seam.
  StatusLineSegmentOptions withPathMaxLength(int maxLength) =>
      StatusLineSegmentOptions(
        modelShowThinkingLevel: modelShowThinkingLevel,
        pathAbbreviate: pathAbbreviate,
        pathMaxLength: maxLength,
        pathStripWorkPrefix: pathStripWorkPrefix,
        gitShowBranch: gitShowBranch,
        gitShowStaged: gitShowStaged,
        gitShowUnstaged: gitShowUnstaged,
        gitShowUntracked: gitShowUntracked,
        time24h: time24h,
        timeShowSeconds: timeShowSeconds,
      );

  /// YAML fragment (the `segmentOptions:` block inside
  /// `tui.statusLine:`), grouped into the `model`/`path`/`git`/`time`
  /// subsections the parser reads, only non-default mentions — the file
  /// stays minimal. Empty string when nothing non-default is set.
  String toYaml() {
    const defaults = StatusLineSegmentOptions();
    String? leaf(String key, Object? value, Object? dflt) {
      if (value == null || value == dflt) return null;
      return '$key: $value';
    }

    List<String> group(List<String?> leaves) =>
        leaves.whereType<String>().toList();
    final model = group([
      leaf(
        'showThinkingLevel',
        modelShowThinkingLevel,
        defaults.modelShowThinkingLevel,
      ),
    ]);
    final path = group([
      leaf('abbreviate', pathAbbreviate, defaults.pathAbbreviate),
      if (pathMaxLength != null && pathMaxLength != defaults.pathMaxLength)
        'maxLength: $pathMaxLength',
      leaf(
        'stripWorkPrefix',
        pathStripWorkPrefix,
        defaults.pathStripWorkPrefix,
      ),
    ]);
    final git = group([
      leaf('showBranch', gitShowBranch, defaults.gitShowBranch),
      leaf('showStaged', gitShowStaged, defaults.gitShowStaged),
      leaf('showUnstaged', gitShowUnstaged, defaults.gitShowUnstaged),
      leaf('showUntracked', gitShowUntracked, defaults.gitShowUntracked),
    ]);
    final time = group([
      if (time24h == false) 'format: 12h',
      leaf('showSeconds', timeShowSeconds, defaults.timeShowSeconds),
    ]);
    String section(String name, List<String> leaves) =>
        '      $name:\n'
        '${leaves.map((l) => '        $l').join('\n')}';
    final sections = [
      if (model.isNotEmpty) section('model', model),
      if (path.isNotEmpty) section('path', path),
      if (git.isNotEmpty) section('git', git),
      if (time.isNotEmpty) section('time', time),
    ];
    if (sections.isEmpty) return '';
    return '    segmentOptions:\n${sections.join('\n')}\n';
  }
}

/// A resolved status-line layout: the left/right segment id groups, the
/// separator style and the merged render options. Produced by
/// [resolveStatusLineSpec]; consumed by [TuiStatusLine].
final class StatusLineSpec {
  final List<String> left;
  final List<String> right;
  final StatusLineSeparatorStyle separator;

  /// Whether the separator glyphs come from the Nerd Font table (the
  /// `nerd` preset). The `ascii` preset never emits nerd glyphs (E4).
  final bool nerdSymbols;

  /// Drop the band fill and end caps (omp's `transparent` flag).
  final bool transparent;
  final StatusLineSegmentOptions options;

  const StatusLineSpec({
    required this.left,
    required this.right,
    required this.separator,
    this.nerdSymbols = false,
    this.transparent = false,
    this.options = const StatusLineSegmentOptions(),
  });
}

/// The 7 presets verbatim from omp `presets.ts` (pinned commit `df624f5`):
/// default/minimal/compact/full/nerd/ascii/custom.
const Map<
  String,
  ({
    List<String> left,
    List<String> right,
    StatusLineSeparatorStyle separator,
    bool nerd,
    StatusLineSegmentOptions options,
  })
>
kStatusLinePresets = {
  'default': (
    left: [
      'pi',
      'vim',
      'model',
      'mode',
      'collab',
      'stream',
      'path',
      'git',
      'pr',
      'context_pct',
      'cost',
    ],
    right: ['session_name'],
    separator: StatusLineSeparatorStyle.powerlineThin,
    nerd: false,
    options: StatusLineSegmentOptions(),
  ),
  'minimal': (
    left: ['vim', 'path', 'git'],
    right: ['session_name', 'mode', 'context_pct'],
    separator: StatusLineSeparatorStyle.slash,
    nerd: false,
    options: StatusLineSegmentOptions(
      pathMaxLength: 30,
      gitShowStaged: false,
      gitShowUnstaged: false,
      gitShowUntracked: false,
    ),
  ),
  'compact': (
    left: ['vim', 'model', 'mode', 'git', 'pr'],
    right: ['session_name', 'cost', 'context_pct'],
    separator: StatusLineSeparatorStyle.powerlineThin,
    nerd: false,
    options: StatusLineSegmentOptions(
      modelShowThinkingLevel: false,
      gitShowUntracked: false,
    ),
  ),
  'full': (
    left: [
      'pi',
      'vim',
      'hostname',
      'model',
      'mode',
      'path',
      'git',
      'pr',
      'subagents',
    ],
    right: [
      'session_name',
      'cache_hit',
      'token_in',
      'token_out',
      'token_rate',
      'cache_read',
      'cost',
      'context_pct',
      'time_spent',
      'time',
    ],
    separator: StatusLineSeparatorStyle.powerline,
    nerd: false,
    options: StatusLineSegmentOptions(pathMaxLength: 50),
  ),
  'nerd': (
    left: [
      'pi',
      'vim',
      'hostname',
      'model',
      'mode',
      'path',
      'git',
      'pr',
      'session',
      'subagents',
    ],
    right: [
      'session_name',
      'token_in',
      'token_out',
      'cache_read',
      'cache_write',
      'token_rate',
      'cost',
      'context_pct',
      'context_total',
      'time_spent',
      'time',
    ],
    separator: StatusLineSeparatorStyle.powerline,
    nerd: true,
    options: StatusLineSegmentOptions(pathMaxLength: 60, timeShowSeconds: true),
  ),
  'ascii': (
    left: ['vim', 'model', 'mode', 'path', 'git', 'pr'],
    right: ['session_name', 'token_total', 'cost', 'context_pct'],
    separator: StatusLineSeparatorStyle.ascii,
    nerd: false,
    options: StatusLineSegmentOptions(),
  ),
  'custom': (
    left: ['vim', 'model', 'mode', 'path', 'git', 'pr'],
    right: ['session_name', 'token_total', 'cost', 'context_pct'],
    separator: StatusLineSeparatorStyle.powerlineThin,
    nerd: false,
    options: StatusLineSegmentOptions(),
  ),
};

/// Preset names accepted by `tui.statusLine.preset`.
const List<String> kStatusLinePresetNames = [
  'default',
  'minimal',
  'compact',
  'full',
  'nerd',
  'ascii',
  'custom',
];

/// The omp 27 segment ids (`schema.ts` `STATUS_LINE_SEGMENT_IDS`). Ids
/// with no fa counterpart data (`usage`, `collab`, `stream`, `vim`,
/// `cache_hit`) stay valid and render hidden — custom configs referencing
/// them keep working (umbrella D2, E7).
const List<String> kStatusLineSegmentIds = [
  'pi',
  'status',
  'model',
  'mode',
  'path',
  'git',
  'pr',
  'subagents',
  'token_in',
  'token_out',
  'token_total',
  'token_rate',
  'cost',
  'context_pct',
  'context_total',
  'time_spent',
  'time',
  'session',
  'hostname',
  'cache_read',
  'cache_write',
  'cache_hit',
  'session_name',
  'usage',
  'collab',
  'stream',
  'vim',
];

/// Separator styles (`tui.statusLine.separator`). omp's `none` renders as
/// bare spacing; the config-facing name here is `space`.
enum StatusLineSeparatorStyle {
  powerline,
  powerlineThin,
  slash,
  pipe,
  block,
  space,
  ascii,
}

/// Parses a separator style name; unknown names are a strict config error.
StatusLineSeparatorStyle parseStatusLineSeparator(String name) {
  for (final style in StatusLineSeparatorStyle.values) {
    if (style.name == name) return style;
  }
  throw ConfigException(
    'unknown "tui.statusLine" separator "$name" (known: '
    '${StatusLineSeparatorStyle.values.map((s) => s.name).join(', ')})',
  );
}

/// Resolves a (possibly null) parsed config into a concrete
/// [StatusLineSpec]: the preset's groups/separator/options as the base,
/// the user's `left:`/`right:`/`separator:`/`segmentOptions:`/
/// `transparent:` overrides merged on top. Explicit `left:`/`right:`
/// without a `preset:` implies the `custom` base. Unknown segment ids are
/// dropped with one [warn] line each — never a boot failure (the
/// `tools:`-scopes rule, E7).
StatusLineSpec resolveStatusLineSpec(
  StatusLineConfig? config, {
  void Function(String message)? warn,
}) {
  final hasCustomGroups = config?.left != null || config?.right != null;
  final presetName = config?.preset ?? (hasCustomGroups ? 'custom' : 'default');
  final preset = kStatusLinePresets[presetName];
  if (preset == null) {
    throw ConfigException(
      'unknown "tui.statusLine" preset: $presetName '
      '(known: ${kStatusLinePresetNames.join(', ')})',
    );
  }
  List<String> kept(List<String>? configured, List<String> fallback) {
    final ids = configured ?? fallback;
    for (final id in ids) {
      if (!kStatusLineSegmentIds.contains(id)) {
        warn?.call(
          'config tui.statusLine: unknown segment id "$id" — ignored '
          '(known: ${kStatusLineSegmentIds.join(', ')})',
        );
      }
    }
    return [
      for (final id in ids)
        if (kStatusLineSegmentIds.contains(id)) id,
    ];
  }

  return StatusLineSpec(
    left: kept(config?.left, preset.left),
    right: kept(config?.right, preset.right),
    separator: config?.separator ?? preset.separator,
    nerdSymbols: preset.nerd,
    transparent: config?.transparent ?? false,
    options:
        config?.segmentOptions?.mergedOver(preset.options) ?? preset.options,
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// Config section — `tui:` (theme / classic / statusLine)
// ═══════════════════════════════════════════════════════════════════════════

/// The parsed `tui:` section: the theme name (`tui.theme`), the legacy
/// chrome kill switch (`tui.classic` — S3's rendering concern, parsed
/// here so the key exists and validates strictly) and the status-line
/// section (`tui.statusLine`).
final class TuiSectionConfig {
  final String? theme;
  final bool classic;
  final StatusLineConfig? statusLine;

  const TuiSectionConfig({this.theme, this.classic = false, this.statusLine});
}

/// Parses the `tui:` yaml section. Strict (the repo's ConfigException
/// conventions): a non-map node, a bad scalar or an unknown key throws —
/// a typo must never silently skip a section. Absent section → defaults.
TuiSectionConfig parseTuiSection(Object? node) {
  if (node == null) return const TuiSectionConfig();
  if (node is! YamlMap) {
    throw ConfigException('tui must be a map, got: $node');
  }
  _checkStrictKeys(node, 'tui', const {'theme', 'classic', 'statusLine'});
  final theme = _tuiThemeName(node['theme']);
  final classic = _tuiClassicFlag(node['classic']);
  final statusLine = node['statusLine'];
  if (statusLine != null && statusLine is! YamlMap) {
    throw ConfigException('"tui.statusLine" must be a map, got: $statusLine');
  }
  return TuiSectionConfig(
    theme: theme,
    classic: classic,
    statusLine: statusLine == null ? null : parseStatusLineConfig(statusLine),
  );
}

/// Validates the `theme:` value; null when unset.
String? _tuiThemeName(Object? theme) {
  if (theme == null) return null;
  if (theme is! String || theme.trim().isEmpty) {
    throw ConfigException('"tui.theme" must be a non-empty theme name');
  }
  return theme;
}

/// Validates the `classic:` kill switch; false when unset.
bool _tuiClassicFlag(Object? classic) {
  if (classic != null && classic is! bool) {
    throw ConfigException('"tui.classic" must be a boolean');
  }
  return classic as bool? ?? false;
}

/// The parsed `tui.statusLine:` section. `preset` selects one of the 7
/// presets; `left:`/`right:` override the segment groups (implying the
/// `custom` base when `preset` is absent); `separator`, `segmentOptions`
/// and `transparent` override the rest. Unknown segment ids are ACCEPTED
/// here and warned+dropped at [resolveStatusLineSpec] — parse resolves
/// structure, resolution resolves names (the `tools:`-scopes split).
final class StatusLineConfig {
  final String? preset;
  final List<String>? left;
  final List<String>? right;
  final StatusLineSeparatorStyle? separator;
  final StatusLineSegmentOptions? segmentOptions;
  final bool transparent;

  const StatusLineConfig({
    this.preset,
    this.left,
    this.right,
    this.separator,
    this.segmentOptions,
    this.transparent = false,
  });

  /// The `tui.statusLine:` yaml block for the config round-trip; empty
  /// when nothing is configured (defaults are never written).
  String toYaml() {
    final lines = <String>[
      if (preset != null) '    preset: $preset',
      if (separator != null) '    separator: ${separator!.name}',
      if (transparent) '    transparent: true',
      if (left != null) '    left: [${left!.join(', ')}]',
      if (right != null) '    right: [${right!.join(', ')}]',
    ];
    final options = segmentOptions?.toYaml() ?? '';
    if (lines.isEmpty && options.isEmpty) return '';
    final head =
        '  statusLine:\n${lines.join('\n')}${lines.isEmpty ? '' : '\n'}';
    return '$head$options';
  }
}

/// Parses the `tui.statusLine:` yaml node. Strict on schema: unknown
/// keys, a non-list `left`/`right`, an unknown preset or separator name,
/// or a non-string segment id all throw [ConfigException].
StatusLineConfig parseStatusLineConfig(Object? node) {
  if (node == null) return const StatusLineConfig();
  if (node is! YamlMap) {
    throw ConfigException('tui.statusLine must be a map, got: $node');
  }
  _checkStrictKeys(node, 'tui.statusLine', const {
    'preset',
    'left',
    'right',
    'separator',
    'segmentOptions',
    'transparent',
  });
  final preset = _statusLinePreset(node['preset']);
  final optionsNode = node['segmentOptions'];
  if (optionsNode != null && optionsNode is! YamlMap) {
    throw ConfigException(
      '"tui.statusLine.segmentOptions" must be a map, got: $optionsNode',
    );
  }
  final transparent = node['transparent'];
  if (transparent != null && transparent is! bool) {
    throw ConfigException('"tui.statusLine.transparent" must be a boolean');
  }
  final separator = node['separator'];
  return StatusLineConfig(
    preset: preset,
    left: _statusLineSegmentIds(node, 'left'),
    right: _statusLineSegmentIds(node, 'right'),
    separator: separator == null
        ? null
        : parseStatusLineSeparator('$separator'),
    segmentOptions: optionsNode == null
        ? null
        : parseSegmentOptions(optionsNode),
    transparent: transparent ?? false,
  );
}

/// Strict-key guard for the `tui` section family: any key outside
/// [knownKeys] throws (a typo must never silently disable a setting).
void _checkStrictKeys(YamlMap node, String path, Set<String> knownKeys) {
  for (final key in node.keys) {
    if (!knownKeys.contains('$key')) {
      throw ConfigException(
        'unknown "$path" key: $key (known: ${knownKeys.join(', ')})',
      );
    }
  }
}

/// Validates the `preset:` value; null when unset.
String? _statusLinePreset(Object? preset) {
  if (preset == null) return null;
  if (preset is! String || !kStatusLinePresetNames.contains(preset)) {
    throw ConfigException(
      'unknown "tui.statusLine" preset: $preset '
      '(known: ${kStatusLinePresetNames.join(', ')})',
    );
  }
  return preset;
}

/// Reads a `left:`/`right:` id list; every entry must be a string.
List<String>? _statusLineSegmentIds(YamlMap node, String key) {
  final value = node[key];
  if (value == null) return null;
  if (value is! YamlList) {
    throw ConfigException(
      '"tui.statusLine.$key" must be a list of segment ids',
    );
  }
  return [
    for (final id in value)
      if (id is! String)
        throw ConfigException(
          '"tui.statusLine.$key" entries must be strings, got: $id',
        )
      else
        id,
  ];
}

/// Parses the `segmentOptions:` node into the explicit-override shape
/// (only the fields the user mentioned are non-null).
StatusLineSegmentOptions parseSegmentOptions(Object? node) {
  final map = node as YamlMap;
  _checkStrictKeys(map, 'tui.statusLine.segmentOptions', const {
    'model',
    'path',
    'git',
    'time',
  });
  final model = _subSection(map, 'model');
  final path = _subSection(map, 'path');
  final git = _subSection(map, 'git');
  final time = _subSection(map, 'time');
  return StatusLineSegmentOptions(
    modelShowThinkingLevel: _boolOpt(model, 'showThinkingLevel'),
    pathAbbreviate: _boolOpt(path, 'abbreviate'),
    pathMaxLength: _positiveInt(path, 'maxLength'),
    pathStripWorkPrefix: _boolOpt(path, 'stripWorkPrefix'),
    gitShowBranch: _boolOpt(git, 'showBranch'),
    gitShowStaged: _boolOpt(git, 'showStaged'),
    gitShowUnstaged: _boolOpt(git, 'showUnstaged'),
    gitShowUntracked: _boolOpt(git, 'showUntracked'),
    time24h: _time24h(time),
    timeShowSeconds: _boolOpt(time, 'showSeconds'),
  );
}

YamlMap? _subSection(YamlMap parent, String key) {
  final value = parent[key];
  if (value == null) return null;
  if (value is! YamlMap) {
    throw ConfigException(
      '"tui.statusLine.segmentOptions.$key" must be a map, got: $value',
    );
  }
  return value;
}

bool? _boolOpt(YamlMap? node, String key) {
  final value = node?[key];
  if (value == null) return null;
  if (value is! bool) {
    throw ConfigException(
      '"tui.statusLine.segmentOptions" "$key" must be a boolean',
    );
  }
  return value;
}

int? _positiveInt(YamlMap? node, String key) {
  final value = node?[key];
  if (value == null) return null;
  if (value is! int || value <= 0) {
    throw ConfigException(
      '"tui.statusLine.segmentOptions" "$key" must be a positive integer',
    );
  }
  return value;
}

bool? _time24h(YamlMap? node) {
  final value = node?['format'];
  if (value == null) return null;
  if (value == '24h') return true;
  if (value == '12h') return false;
  throw ConfigException(
    '"tui.statusLine.segmentOptions.time.format" must be "24h" or "12h"',
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// Separators (omp separators.ts + the symbol tables)
// ═══════════════════════════════════════════════════════════════════════════

/// One resolved separator style: the glyph between group members
/// ([left]/[right] by group direction) and the optional end caps that
/// bridge the band fill into the terminal bg ([capAfterLeft] closes the
/// left group, [capBeforeRight] opens the right one).
///
/// Caps are BAND edges, not segment content: they are painted by S3's
/// band composer (#806) reading these fields — `fg=band-bg` per omp's
/// `useBgAsFg`, which only makes sense once the composer also paints
/// the band fill this render-only story deliberately drops (the same
/// split as `StatusLineSpec.transparent`). The span stream here stays
/// cap-free; glyph parity with omp is pinned by tests.
final class StatusLineSeparator {
  final String left;
  final String right;
  final String? capAfterLeft;
  final String? capBeforeRight;

  const StatusLineSeparator({
    required this.left,
    required this.right,
    this.capAfterLeft,
    this.capBeforeRight,
  });
}

/// Separator glyphs by style. The plain table is font-safe unicode; the
/// nerd table swaps the powerline shapes for Nerd Font private-use
/// glyphs (only the `nerd` preset sets [StatusLineSpec.nerdSymbols]).
StatusLineSeparator getSeparator(
  StatusLineSeparatorStyle style, {
  bool nerd = false,
}) {
  final pwLeft = nerd ? '\u{e0b0}' : '▶';
  final pwRight = nerd ? '\u{e0b2}' : '◀';
  final pwThinLeft = nerd ? '\u{e0b1}' : '>';
  final pwThinRight = nerd ? '\u{e0b3}' : '<';
  return switch (style) {
    StatusLineSeparatorStyle.powerline => StatusLineSeparator(
      left: pwLeft,
      right: pwRight,
      capAfterLeft: pwRight,
      capBeforeRight: pwLeft,
    ),
    StatusLineSeparatorStyle.powerlineThin => StatusLineSeparator(
      left: pwThinLeft,
      right: pwThinRight,
      // Full-width caps even for the thin style (omp verbatim).
      capAfterLeft: pwRight,
      capBeforeRight: pwLeft,
    ),
    StatusLineSeparatorStyle.slash => const StatusLineSeparator(
      left: '/',
      right: '/',
    ),
    StatusLineSeparatorStyle.pipe => const StatusLineSeparator(
      left: '│',
      right: '│',
    ),
    StatusLineSeparatorStyle.block => StatusLineSeparator(
      left: nerd ? '█' : '▌',
      right: nerd ? '█' : '▌',
    ),
    StatusLineSeparatorStyle.space => const StatusLineSeparator(
      left: ' ',
      right: ' ',
    ),
    StatusLineSeparatorStyle.ascii => const StatusLineSeparator(
      left: '>',
      right: '<',
    ),
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Gauge math + brand fade
// ═══════════════════════════════════════════════════════════════════════════

/// Context gauge pressure levels: the 50 % warn / 90 % error thresholds.
enum StatusLineGaugeLevel { normal, warn, error }

/// The gauge level for [percent]: ≥90 error, ≥50 warn, else normal.
StatusLineGaugeLevel statusLineGaugeLevel(double percent) {
  if (percent >= 90) return StatusLineGaugeLevel.error;
  if (percent >= 50) return StatusLineGaugeLevel.warn;
  return StatusLineGaugeLevel.normal;
}

/// omp's embedded-gauge percent format: `toFixed(1)` ONLY below 1 %,
/// integer otherwise (`0.3%`, `42%`, `100%`).
String formatStatusLinePercent(double percent) =>
    '${percent > 0 && percent < 1 ? percent.toStringAsFixed(1) : percent.round()}%';

/// Minimum gap the embedded gauge needs to show both labels:
/// percent label + window label + the 4 bridging cells (omp's
/// `embeddedContextGaugeMinWidth`).
int statusLineGaugeMinWidth(double percent, int contextWindow) =>
    formatStatusLinePercent(percent).length +
    formatTokens(contextWindow).length +
    4;

/// The `pi` brand-mark fade tween: 0.0 = fully idle-dim, 1.0 = fully lit,
/// quantized to [frameMs] frames across [durationMs] (omp: 450 ms / 40 ms,
/// 11 sampled frames + settle). [changedAgoMs] is the time since the last
/// idle↔working flip (`null` = static: [lit] decides). Pure — the host
/// owns the clock.
double statusLineBrandFadeT({
  required bool lit,
  required int? changedAgoMs,
  int durationMs = 450,
  int frameMs = 40,
}) {
  if (changedAgoMs == null || changedAgoMs >= durationMs) {
    return lit ? 1.0 : 0.0;
  }
  final frames = durationMs ~/ frameMs;
  if (frames <= 0) {
    // Degenerate tuning (frameMs > durationMs): no tween room - snap.
    return lit ? 1.0 : 0.0;
  }
  final t = (changedAgoMs ~/ frameMs) / frames;
  return lit ? t : 1.0 - t;
}

// ═══════════════════════════════════════════════════════════════════════════
// Segment renderers — the 27-id registry
// ═══════════════════════════════════════════════════════════════════════════

/// One styled run of segment text: the raw text (layout math runs on
/// these) plus the role key that paints it at write time.
typedef StatusSpan = (String text, StatusLineRoleKey role);

/// One laid-out segment: its id (drives the truncation ladder's path
/// handling) plus its rendered spans.
final class LaidSegment {
  final String id;
  final List<StatusSpan> spans;

  const LaidSegment(this.id, this.spans);

  /// Raw text (spans concatenated).
  String get text => spans.map((s) => s.$1).join();

  /// Terminal-cell width of the raw text.
  int get width => tuiTextWidth(text);
}

/// Renders segment text on a `~`-abbreviated, length-clamped cwd
/// (omp's `shortenPath` semantics: abbreviate `~/`, then tuiFitWidth to
/// [maxLength] cells, then collapse leading components when still cut —
/// the ladder re-renders through [StatusLineSegmentOptions.withPathMaxLength]).
String abbreviateSegmentPath(
  String cwd, {
  String? homeDir,
  required bool abbreviate,
  required int maxLength,
  String? workRoot,
  required bool stripWorkPrefix,
}) {
  var path = cwd;
  // Work-root strip first (raw path): inside the workspace the display
  // root is the workspace itself, so `~` never appears.
  if (stripWorkPrefix &&
      workRoot != null &&
      workRoot.isNotEmpty &&
      (path == workRoot || path.startsWith('$workRoot/'))) {
    return tuiFitWidth(
      path == workRoot ? '.' : path.substring(workRoot.length + 1),
      maxLength,
    );
  }
  return _homeAbbreviatedFit(
    path,
    abbreviate: abbreviate,
    homeDir: homeDir,
    maxLength: maxLength,
  );
}

/// The `~` half of [abbreviateSegmentPath]: the home dir itself collapses
/// to a RAW `~` (never re-clamped), anything under it to `~/rest`, else
/// the untouched path clamps to [maxLength].
String _homeAbbreviatedFit(
  String path, {
  required bool abbreviate,
  required String? homeDir,
  required int maxLength,
}) {
  if (abbreviate && homeDir != null && homeDir.isNotEmpty) {
    if (path == homeDir) return '~';
    if (path.startsWith('$homeDir/')) {
      return tuiFitWidth('~/${path.substring(homeDir.length + 1)}', maxLength);
    }
  }
  return tuiFitWidth(path, maxLength);
}

/// Parses `git status --porcelain` output (the git watcher seam's
/// fixture format) into counts + branch (from `## branch...` header;
/// detached heads report the short sha). Pure — the host runs git.
StatusLineGit parseGitStatusPorcelain(String output) {
  var staged = 0;
  var unstaged = 0;
  var untracked = 0;
  String? branch;
  for (final line in output.split('\n')) {
    if (line.isEmpty) continue;
    if (line.startsWith('## ')) {
      final header = line.substring(3);
      // An initial repo has no branch yet (`## No commits yet on main`);
      // report branch-less rather than adopting the sentence as a name.
      if (header.startsWith('No commits yet')) continue;
      final dot = header.indexOf('...');
      final bracket = header.indexOf('[');
      branch = header
          .substring(0, dot < 0 ? (bracket < 0 ? header.length : bracket) : dot)
          .trim();
      continue;
    }
    if (line.length < 2) continue;
    final x = line[0];
    final y = line[1];
    // `!` = ignored files (only reported with --ignored): they are not
    // untracked work, so they never count toward `?N`.
    if (x == '?') {
      untracked++;
    } else if (x == '!') {
      continue;
    } else {
      if (x != ' ') staged++;
      if (y != ' ') unstaged++;
    }
  }
  return StatusLineGit(
    branch: branch,
    staged: staged,
    unstaged: unstaged,
    untracked: untracked,
  );
}

/// The `time`/`time_spent` clock form: `HH:MM(:SS)` in 24h, or
/// `H:MM(:SS) AM/PM` in 12h (compact 24h form `H:MM` for durations).
String formatStatusLineClock(
  DateTime now, {
  required bool clock24h,
  required bool showSeconds,
}) {
  var hour = now.hour;
  var suffix = '';
  if (!clock24h) {
    suffix = now.hour < 12 ? ' AM' : ' PM';
    hour = now.hour % 12;
    if (hour == 0) hour = 12;
  }
  final hh = clock24h ? hour.toString().padLeft(2, '0') : '$hour';
  final mm = now.minute.toString().padLeft(2, '0');
  return '$hh:$mm${showSeconds ? ':${now.second.toString().padLeft(2, '0')}' : ''}$suffix';
}

/// Compactly renders a duration for `time_spent`: `21:03` under an hour,
/// `1:02:03` and beyond otherwise (omp's compact clock form).
String formatStatusLineDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

LaidSegment? _renderPi(StatusLineSnapshot s, StatusLineSpec spec) {
  // The brand mark: `>_Fa` with the fade handled at paint time (the
  // painter blends toward the dim endpoint via [statusLineBrandFadeT]).
  return const LaidSegment('pi', [
    ('>_', StatusLineRoleKey.brandA),
    ('Fa', StatusLineRoleKey.brandB),
  ]);
}

LaidSegment? _renderVim(StatusLineSnapshot s, StatusLineSpec spec) {
  // No vim-mode state in the snapshot yet (S3 wires the keybindings) —
  // renders hidden (data absence, E7).
  return null;
}

LaidSegment? _renderModel(StatusLineSnapshot s, StatusLineSpec spec) {
  final model = s.modelName;
  if (model == null || model.isEmpty) return null;
  final spans = <StatusSpan>[(model, StatusLineRoleKey.model)];
  if (spec.options.showThinkingLevel) {
    final level = s.thinkingLevel;
    if (level != null && level.isNotEmpty) {
      spans.add((' · $level', StatusLineRoleKey.mode));
    }
  }
  return LaidSegment('model', spans);
}

LaidSegment? _renderMode(StatusLineSnapshot s, StatusLineSpec spec) {
  final approval = s.approvalMode;
  final load = s.agentLoadMode;
  final parts = [
    if (approval != null && approval.isNotEmpty) approval,
    if (load != null && load.isNotEmpty && load != 'default') load,
  ];
  if (parts.isEmpty) return null;
  return LaidSegment('mode', [(parts.join(' '), StatusLineRoleKey.mode)]);
}

LaidSegment? _renderPath(StatusLineSnapshot s, StatusLineSpec spec) {
  final text = abbreviateSegmentPath(
    s.cwd,
    homeDir: s.homeDir,
    abbreviate: spec.options.abbreviate,
    maxLength: spec.options.maxLength,
    workRoot: s.workRoot,
    stripWorkPrefix: spec.options.stripWorkPrefix,
  );
  if (text.isEmpty) return null;
  return LaidSegment('path', [(text, StatusLineRoleKey.path)]);
}

LaidSegment? _renderGit(StatusLineSnapshot s, StatusLineSpec spec) {
  final git = s.git;
  if (git == null) return null;
  final branch = git.branch;
  final counts = git.staged + git.unstaged + git.untracked;
  if ((branch == null || branch.isEmpty) && counts == 0) return null;
  final spans = _gitSpans(branch, git, spec.options);
  if (spans.isEmpty) return null;
  return LaidSegment('git', spans);
}

/// The git tail spans: the branch, then the dirty markers in omp's
/// order (unstaged `*n`, staged `+n`, untracked `?n`), each behind its
/// `segmentOptions.git.*` toggle and only when its count is nonzero.
List<StatusSpan> _gitSpans(
  String? branch,
  StatusLineGit git,
  StatusLineSegmentOptions o,
) {
  final spans = <StatusSpan>[];
  if (branch != null && branch.isNotEmpty && o.showBranch) {
    spans.add((branch, StatusLineRoleKey.gitClean));
  }
  if (o.showUnstaged && git.unstaged > 0) {
    spans.add((' *${git.unstaged}', StatusLineRoleKey.gitDirty));
  }
  if (o.showStaged && git.staged > 0) {
    spans.add((' +${git.staged}', StatusLineRoleKey.gitStaged));
  }
  if (o.showUntracked && git.untracked > 0) {
    spans.add((' ?${git.untracked}', StatusLineRoleKey.gitUntracked));
  }
  return spans;
}

LaidSegment? _renderPr(StatusLineSnapshot s, StatusLineSpec spec) {
  final pr = s.pr;
  if (pr == null || pr.isEmpty) return null;
  return LaidSegment('pr', [(pr, StatusLineRoleKey.pr)]);
}

LaidSegment? _renderSubagents(StatusLineSnapshot s, StatusLineSpec spec) {
  if (s.subagents <= 0) return null;
  return LaidSegment('subagents', [
    ('⧉${s.subagents}', StatusLineRoleKey.subagents),
  ]);
}

LaidSegment? _renderTokenIn(StatusLineSnapshot s, StatusLineSpec spec) =>
    s.tokensIn <= 0
    ? null
    : LaidSegment('token_in', [
        ('↑${formatTokens(s.tokensIn)}', StatusLineRoleKey.output),
      ]);

LaidSegment? _renderTokenOut(StatusLineSnapshot s, StatusLineSpec spec) =>
    s.tokensOut <= 0
    ? null
    : LaidSegment('token_out', [
        ('↓${formatTokens(s.tokensOut)}', StatusLineRoleKey.output),
      ]);

LaidSegment? _renderTokenTotal(StatusLineSnapshot s, StatusLineSpec spec) {
  final total = s.tokensIn + s.tokensOut;
  if (total <= 0) return null;
  return LaidSegment('token_total', [
    ('Σ${formatTokens(total)}', StatusLineRoleKey.output),
  ]);
}

LaidSegment? _renderTokenRate(StatusLineSnapshot s, StatusLineSpec spec) {
  final rate = s.tokensPerSecond;
  if (rate == null || rate <= 0) return null;
  final formatted = rate >= 100
      ? rate.round().toString()
      : rate.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return LaidSegment('token_rate', [
    ('$formatted t/s', StatusLineRoleKey.output),
  ]);
}

LaidSegment? _renderCost(StatusLineSnapshot s, StatusLineSpec spec) {
  final cost = s.costUsd;
  if (cost == null) return null; // null = unpriced: hide, never $0.00
  return LaidSegment('cost', [
    ('\$${cost.toStringAsFixed(2)}', StatusLineRoleKey.spend),
  ]);
}

LaidSegment? _renderContextPct(StatusLineSnapshot s, StatusLineSpec spec) {
  if (s.contextWindow <= 0) return null;
  final pct = s.contextPercent!;
  final level = statusLineGaugeLevel(pct);
  final role = switch (level) {
    StatusLineGaugeLevel.normal => StatusLineRoleKey.context,
    StatusLineGaugeLevel.warn => StatusLineRoleKey.warn,
    StatusLineGaugeLevel.error => StatusLineRoleKey.error,
  };
  return LaidSegment('context_pct', [
    ('${formatStatusLinePercent(pct)}/${formatTokens(s.contextWindow)}', role),
  ]);
}

LaidSegment? _renderContextTotal(StatusLineSnapshot s, StatusLineSpec spec) {
  if (s.contextWindow <= 0) return null;
  return LaidSegment('context_total', [
    (formatTokens(s.contextWindow), StatusLineRoleKey.context),
  ]);
}

LaidSegment? _renderTimeSpent(StatusLineSnapshot s, StatusLineSpec spec) {
  if (s.elapsed <= Duration.zero) return null;
  return LaidSegment('time_spent', [
    (formatStatusLineDuration(s.elapsed), StatusLineRoleKey.time),
  ]);
}

LaidSegment? _renderTime(StatusLineSnapshot s, StatusLineSpec spec) {
  final now = s.now;
  if (now == null) return null;
  return LaidSegment('time', [
    (
      formatStatusLineClock(
        now,
        clock24h: spec.options.clock24h,
        showSeconds: spec.options.showSeconds,
      ),
      StatusLineRoleKey.time,
    ),
  ]);
}

/// `session`: the short session-id slot (omp's left-group surface).
/// Absent data hides (E7) - the `'new'` stand-in belongs to
/// `_renderSessionName` alone.
LaidSegment? _renderSessionId(StatusLineSnapshot s, StatusLineSpec spec) {
  final id = s.sessionId;
  if (id == null || id.isEmpty) return null;
  return LaidSegment('session', [
    (id.length < 8 ? id : id.substring(0, 8), StatusLineRoleKey.name),
  ]);
}

/// `session_name`: the session title; an unnamed session falls back to
/// the short id, then to omp's `'new'` stand-in.
LaidSegment? _renderSessionName(StatusLineSnapshot s, StatusLineSpec spec) {
  final name = s.sessionName;
  if (name != null && name.isNotEmpty) {
    return LaidSegment('session_name', [(name, StatusLineRoleKey.name)]);
  }
  final id = s.sessionId;
  if (id == null || id.isEmpty) {
    return const LaidSegment('session_name', [('new', StatusLineRoleKey.name)]);
  }
  return LaidSegment('session_name', [
    (id.length < 8 ? id : id.substring(0, 8), StatusLineRoleKey.name),
  ]);
}

LaidSegment? _renderHostname(StatusLineSnapshot s, StatusLineSpec spec) {
  final host = s.hostname;
  if (host == null || host.isEmpty) return null;
  return LaidSegment('hostname', [(host, StatusLineRoleKey.dim)]);
}

// Data-absent ids: no fa counterpart yet (E7) — valid ids, always hidden.
LaidSegment? _renderUsage(StatusLineSnapshot s, StatusLineSpec spec) => null;
LaidSegment? _renderCollab(StatusLineSnapshot s, StatusLineSpec spec) => null;
LaidSegment? _renderStream(StatusLineSnapshot s, StatusLineSpec spec) {
  // Spinner glyph only while streaming; idle has no data → hidden.
  if (s.idle) return null;
  return const LaidSegment('stream', [('…', StatusLineRoleKey.output)]);
}

LaidSegment? _renderCacheRead(StatusLineSnapshot s, StatusLineSpec spec) =>
    s.cacheRead <= 0
    ? null
    : LaidSegment('cache_read', [
        ('⟲${formatTokens(s.cacheRead)}', StatusLineRoleKey.output),
      ]);

LaidSegment? _renderCacheWrite(StatusLineSnapshot s, StatusLineSpec spec) =>
    s.cacheWrite <= 0
    ? null
    : LaidSegment('cache_write', [
        ('⟳${formatTokens(s.cacheWrite)}', StatusLineRoleKey.output),
      ]);

LaidSegment? _renderCacheHit(StatusLineSnapshot s, StatusLineSpec spec) =>
    // omp keeps `cache_hit` in the 27-id table with no renderer (verified
    // against its segments.ts) — faithful hidden-constant here too.
    null;

LaidSegment? _renderStatus(StatusLineSnapshot s, StatusLineSpec spec) {
  // omp's `status` segment: the spinner while working, hidden when idle.
  if (s.idle) return null;
  return const LaidSegment('status', [('⠿', StatusLineRoleKey.output)]);
}

/// The registry: omp's 27 segment ids → fa renderers. A renderer returns
/// `null` when its data is absent — the segment hides (E7), never
/// rendering a placeholder. Unmodifiable: consumers must never mutate
/// the shared table.
final Map<
  String,
  LaidSegment? Function(StatusLineSnapshot s, StatusLineSpec spec)
>
kStatusLineSegments = UnmodifiableMapView(
  <String, LaidSegment? Function(StatusLineSnapshot s, StatusLineSpec spec)>{
    'pi': _renderPi,
    'status': _renderStatus,
    'model': _renderModel,
    'mode': _renderMode,
    'path': _renderPath,
    'git': _renderGit,
    'pr': _renderPr,
    'subagents': _renderSubagents,
    'token_in': _renderTokenIn,
    'token_out': _renderTokenOut,
    'token_total': _renderTokenTotal,
    'token_rate': _renderTokenRate,
    'cost': _renderCost,
    'context_pct': _renderContextPct,
    'context_total': _renderContextTotal,
    'time_spent': _renderTimeSpent,
    'time': _renderTime,
    'session': _renderSessionId,
    'hostname': _renderHostname,
    'cache_read': _renderCacheRead,
    'cache_write': _renderCacheWrite,
    'cache_hit': _renderCacheHit,
    'session_name': _renderSessionName,
    'usage': _renderUsage,
    'collab': _renderCollab,
    'stream': _renderStream,
    'vim': _renderVim,
  },
);

/// Lays out one configured group into rendered segments. Unknown ids
/// (a hand-built spec bypassing [resolveStatusLineSpec]'s warn+drop)
/// and absent data both hide (E7) — never a crash inside the frame.
List<LaidSegment> _layoutGroup(
  List<String> ids,
  StatusLineSnapshot s,
  StatusLineSpec spec,
) => [for (final id in ids) ?kStatusLineSegments[id]?.call(s, spec)];

// ═══════════════════════════════════════════════════════════════════════════
// The engine — layout, truncation ladder, gauge fill
// ═══════════════════════════════════════════════════════════════════════════

/// Joins laid segments into group spans: member spans with the
/// separator chunk (` glyph ` padded) between them, separator runs
/// carrying the separator role. Spans and width are computed once —
/// the ladder re-reads `.width` across steps, but groups are
/// immutable after construction, so both are cached.
final class _Group {
  final List<LaidSegment> segments;
  final StatusLineSeparator separator;

  _Group(this.segments, this.separator);

  late final List<StatusSpan> spans = () {
    final glyph = separator.left;
    final out = <StatusSpan>[];
    for (final seg in segments) {
      if (out.isNotEmpty) {
        out.add((' $glyph ', StatusLineRoleKey.separator));
      }
      out.addAll(seg.spans);
    }
    return out;
  }();

  late final int width = spans.fold(0, (w, s) => w + tuiTextWidth(s.$1));
}

/// Renders one status-bar frame as role-keyed spans.
///
/// Layout algorithm (omp `component.ts` ladder):
/// 1. Lay out both groups from the snapshot (absent data → hidden
///    segments dropped).
/// 2. **session_name → right pops → path shrink → left drops**: shrink
///    `session_name` (8 → 4 → drop), then drop right-group members
///    right-to-left, then re-render `path` at shrinking maxLengths
///    (stepwise −10 down to 10), then drop left-group members — until
///    the bar fits [width].
/// 3. Fill the middle with the embedded context gauge when the context
///    window is known and the gap fits it (labels at the edges, a `━`
///    scale between; 50 % warn / 90 % error levels); narrower gaps show
///    the bare percent, and an irreducible overflow collapses to
///    `left + ' ' + right`.
///
/// `spec.transparent` (omp's band-less mode) drops the pure gap fill:
/// content — segments, separators, gauge — still renders, but no dim
/// space run pads the line out to [width], so the terminal bg shows
/// through and the returned line may be shorter than [width].
///
/// Pure: reads the snapshot, measures raw strings, returns raw spans —
/// colors are applied at write time via [statusLineStyle] /
/// [kStatusLineRoles] (the [FaThemeController] emitter seam).
List<StatusSpan> renderStatusLineSpans(
  StatusLineSnapshot snapshot,
  StatusLineSpec spec,
  int width,
) {
  if (width <= 0) return [];
  final leftIn = _layoutGroup(spec.left, snapshot, spec);
  final rightIn = _layoutGroup(spec.right, snapshot, spec);
  if (leftIn.isEmpty && rightIn.isEmpty) return [];

  final sep = getSeparator(spec.separator, nerd: spec.nerdSymbols);
  final squeezed = _squeezeGroups(leftIn, rightIn, snapshot, spec, sep, width);
  final leftW = squeezed.left.width;
  final rightW = squeezed.right.width;
  final gap = width - leftW - rightW;

  // Irreducible overflow: collapse to `left + ' ' + right` (omp).
  if (gap < 1) {
    return [
      ...squeezed.left.spans,
      if (leftW > 0 && rightW > 0) (' ', StatusLineRoleKey.dim),
      ...squeezed.right.spans,
    ];
  }

  final pct = snapshot.contextPercent;
  if (pct == null || snapshot.contextWindow <= 0) {
    return [
      ...squeezed.left.spans,
      // Transparent: no band fill — the terminal bg shows through.
      if (!spec.transparent) (' ' * gap, StatusLineRoleKey.dim),
      ...squeezed.right.spans,
    ];
  }

  final gauge = _gaugeSpans(
    gap,
    pct,
    snapshot.contextWindow,
    transparent: spec.transparent,
  );
  return [...squeezed.left.spans, ...gauge, ...squeezed.right.spans];
}

/// One ladder outcome: the two groups after elastic squeezing, ready to
/// spanify.
final class _Squeezed {
  final _Group left;
  final _Group right;
  _Squeezed(this.left, this.right);
}

/// Ladder step 1 body: re-renders `session_name` clamped to [nameMax]
/// cells; every other right-group member passes through.
List<LaidSegment> _shrinkSessionName(List<LaidSegment> right, int nameMax) => [
  for (final seg in right)
    if (seg.id != 'session_name')
      seg
    else
      LaidSegment('session_name', [
        (tuiFitWidth(seg.text, nameMax), StatusLineRoleKey.name),
      ]),
];

/// The elastic truncation ladder (omp): shrink `session_name` to 8 then
/// 4 cells, drop right-group members right-to-left, re-render `path` at
/// shrinking maxLengths, drop left-group members left-to-right. Stops
/// at the first step that fits.
_Squeezed _squeezeGroups(
  List<LaidSegment> leftIn,
  List<LaidSegment> rightIn,
  StatusLineSnapshot snapshot,
  StatusLineSpec spec,
  StatusLineSeparator sep,
  int width,
) {
  var left = leftIn;
  var right = rightIn;
  var leftGroup = _Group(left, sep);
  var rightGroup = _Group(right, sep);

  // Step 1: shrink session_name to 8, then 4 cells.
  for (final nameMax in const [8, 4]) {
    if (leftGroup.width + rightGroup.width <= width) break;
    right = _shrinkSessionName(right, nameMax);
    rightGroup = _Group(right, sep);
  }
  if (leftGroup.width + rightGroup.width <= width) {
    return _Squeezed(leftGroup, rightGroup);
  }

  // Step 2: drop right-group members right-to-left.
  while (right.isNotEmpty && leftGroup.width + rightGroup.width > width) {
    right = right.sublist(0, right.length - 1);
    rightGroup = _Group(right, sep);
  }

  // Step 3: re-render the path at shrinking maxLengths.
  left = _shrinkPath(left, snapshot, spec, sep, rightGroup.width, width);
  leftGroup = _Group(left, sep);

  // Step 4: drop left-group members left-to-right.
  while (left.isNotEmpty && leftGroup.width + rightGroup.width > width) {
    left = left.sublist(1);
    leftGroup = _Group(left, sep);
  }
  return _Squeezed(leftGroup, rightGroup);
}

/// Ladder step 3 body: re-renders the `path` segment at maxLengths
/// stepping down by 10 to the floor of 10 while the row overflows;
/// a segment whose data vanished mid-shrink stops the loop.
List<LaidSegment> _shrinkPath(
  List<LaidSegment> left,
  StatusLineSnapshot snapshot,
  StatusLineSpec spec,
  StatusLineSeparator sep,
  int rightW,
  int width,
) {
  final pathIndex = left.indexWhere((seg) => seg.id == 'path');
  if (pathIndex < 0) return left;
  final shrunk = [...left];
  var leftGroup = _Group(shrunk, sep);
  var options = spec.options;
  for (
    var maxLength = options.maxLength;
    maxLength >= 10 && leftGroup.width + rightW > width;
    maxLength -= 10
  ) {
    options = options.withPathMaxLength(maxLength);
    final re = _renderPath(
      snapshot,
      StatusLineSpec(
        left: const [],
        right: const [],
        separator: spec.separator,
        options: options,
      ),
    );
    if (re == null) break;
    shrunk[pathIndex] = re;
    leftGroup = _Group(shrunk, sep);
  }
  return shrunk;
}

/// The embedded context gauge filling the gap: the full
/// `pct ━ scale window` form, a centered bare percent, or a plain gap
/// as space runs out. The fill/role track the gauge level. Under
/// [transparent] the plain-gap fallback renders nothing (no band
/// fill); the bare-percent centering pads stay so the percent stays
/// readable mid-gap.
List<StatusSpan> _gaugeSpans(
  int gap,
  double pct,
  int contextWindow, {
  required bool transparent,
}) {
  final pctLabel = formatStatusLinePercent(pct);
  final windowLabel = formatTokens(contextWindow);
  final role = switch (statusLineGaugeLevel(pct)) {
    StatusLineGaugeLevel.normal => StatusLineRoleKey.gaugeUsed,
    StatusLineGaugeLevel.warn => StatusLineRoleKey.warn,
    StatusLineGaugeLevel.error => StatusLineRoleKey.error,
  };
  // Full form: pct label + `━` scale + window label, padded one cell
  // into each group. Narrower: bare percent. Narrowest: plain gap.
  if (gap >= statusLineGaugeMinWidth(pct, contextWindow)) {
    final scaleWidth = gap - pctLabel.length - windowLabel.length - 2;
    final usedCount = ((pct.clamp(0, 100) / 100) * scaleWidth).round().clamp(
      0,
      scaleWidth,
    );
    return <StatusSpan>[
      (' $pctLabel', role),
      ('━' * usedCount, StatusLineRoleKey.gaugeUsed),
      ('━' * (scaleWidth - usedCount), StatusLineRoleKey.gaugeUnused),
      ('$windowLabel ', StatusLineRoleKey.context),
    ];
  }
  if (gap >= pctLabel.length + 2) {
    return <StatusSpan>[
      (' ' * ((gap - pctLabel.length) ~/ 2), StatusLineRoleKey.dim),
      (pctLabel, role),
      (
        ' ' * (gap - pctLabel.length - (gap - pctLabel.length) ~/ 2),
        StatusLineRoleKey.dim,
      ),
    ];
  }
  if (transparent) return const [];
  return <StatusSpan>[(' ' * gap, StatusLineRoleKey.dim)];
}

/// The raw width-correct rows for one frame — the pure [TuiStatusLine]
/// render output (tests pin these strings).
List<String> renderStatusLine(
  StatusLineSnapshot snapshot,
  StatusLineSpec spec,
  int width,
) {
  final spans = renderStatusLineSpans(snapshot, spec, width);
  if (spans.isEmpty) return const [];
  final line = spans.map((s) => s.$1).join();
  // E1 invariant belt: the ladder is width-exact, but a pathological
  // single-huge-segment run truncates as the last resort.
  return [tuiTextWidth(line) > width ? tuiFitWidth(line, width) : line];
}

/// The write-time color seam: resolves one span's role key onto the
/// CURRENT theme ([FaThemeController.current] at the writer), applying
/// the idle dim and the `pi` brand fade blend. Pure given its arguments;
/// the S3 band writer calls this per span as it emits SGR.
Style statusLineStyle(
  StatusLineRoleKey key, {
  required TuiTheme theme,
  required bool idle,
  double brandT = 1.0,
}) {
  final base = kStatusLineRoles[key]!(theme);
  if (key == StatusLineRoleKey.brandA || key == StatusLineRoleKey.brandB) {
    if (brandT >= 1) return base;
    final dim = theme.muted;
    final from = dim.foregroundRgb;
    final to = base.foregroundRgb;
    if (from == null || to == null) return brandT < 0.5 ? dim : base;
    return Style(
      foregroundRgb: RgbColor(
        (from.r + (to.r - from.r) * brandT).round(),
        (from.g + (to.g - from.g) * brandT).round(),
        (from.b + (to.b - from.b) * brandT).round(),
      ),
    );
  }
  return idle ? theme.muted : base;
}

/// The TUI status bar engine. Construct once with a resolved
/// [StatusLineSpec]; call [render] per frame tick with the host-built
/// [StatusLineSnapshot] and the terminal width. Pure — no IO, no clock,
/// no theme-controller reads: layout is raw-string math, colors are the
/// write-time [statusLineStyle] seam.
final class TuiStatusLine {
  final StatusLineSpec spec;

  const TuiStatusLine({required this.spec});

  /// Renders the bar as width-correct raw lines (one line per row; the
  /// single-row bar is the only shape today, kept `List<String>` for the
  /// S3 band composer).
  List<String> render(StatusLineSnapshot snapshot, int width) =>
      renderStatusLine(snapshot, spec, width);

  /// The role-keyed spans behind [render] — the write-time painter's
  /// input (S3's band composer styles each span via [statusLineStyle]).
  List<StatusSpan> renderSpans(StatusLineSnapshot snapshot, int width) =>
      renderStatusLineSpans(snapshot, spec, width);
}
