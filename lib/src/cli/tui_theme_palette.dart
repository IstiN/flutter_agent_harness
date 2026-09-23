// Vendored from the dart_tui fork (`vendor/dart_tui/lib/src/bubbles/themes.dart`,
// issue #613): the fork extends the hosted `Theme` with fah's #444 roles
// (accent2, userMessageBg, tool* — absent from hosted dart_tui), so the
// published package cannot reference the fork-only fields. fah carries its
// own palette type instead, renamed `TuiTheme` to avoid clashing with the
// barrel's `Theme`. Byte-identical role data EXCEPT the roles tagged
// `gh-671 readability:` — deliberate contrast-floor adjustments (muted /
// toolOutput / toolErrorBg for nord and dracula), not upstream drift.
import 'package:dart_tui/src/bubbles/style.dart' show Border, RgbColor, Style;

/// A named collection of [Style] presets for common semantic roles.
///
/// Use the built-in themes ([catppuccin], [nord], [dracula]) or construct
/// your own. Component `XxxStyles.defaults` are pre-wired with
/// [catppuccin] colors so you get beautiful output out of the box — no
/// configuration required.
final class TuiTheme {
  const TuiTheme({
    required this.name,
    required this.base,
    required this.muted,
    required this.accent,
    required this.highlight,
    required this.success,
    required this.warning,
    required this.error,
    required this.border,
    required this.focusBorder,
    this.accent2 = const Style(),
    this.accent2Soft = const Style(),
    this.userMessageBg = const Style(),

    /// Settled/closed row border (dark, quiet). Unset renders plain —
    /// never a fallback color (issue #444 role table).
    this.borderMuted = const Style(),

    /// Tool-row label role (the tool name in `✓ bash · cmd`).
    this.toolTitle = const Style(),

    /// Tool-row detail/output role (command, path, question text).
    this.toolOutput = const Style(),

    /// Foreground of echoed user-message lines (readability floor:
    /// ≥ 7:1 against [userMessageBg] in every built-in palette).
    this.userMessageText = const Style(),

    /// Successful tool row tint (subtle background).
    this.toolSuccessBg = const Style(),

    /// Failed tool row tint (subtle background).
    this.toolErrorBg = const Style(),

    // ── issue #804 (omp S1): the token families the follow-up stories
    // consume, token-for-token from omp `dark.json`/`light.json` (pinned
    // df624f5). Roles a palette leaves unset render plain — never a
    // fallback color (issue #444 role-table rule).

    /// Pending tool row tint (subtle background) — S2 tool cards.
    this.toolPendingBg = const Style(),

    /// Background of custom (slash-command) message lines.
    this.customMessageBg = const Style(),

    /// Foreground of custom message text over [customMessageBg].
    this.customMessageText = const Style(),

    /// Thinking-block body text (S4 thinking panels).
    this.thinkingText = const Style(),

    /// Thinking intensity scale (S4): the level indicator color steps
    /// from faint (off) to vivid (xhigh). Rendered as level labels.
    this.thinkingOff = const Style(),
    this.thinkingMinimal = const Style(),
    this.thinkingLow = const Style(),
    this.thinkingMedium = const Style(),
    this.thinkingHigh = const Style(),
    this.thinkingXhigh = const Style(),

    /// Markdown transcript roles (S5): heading, link text, the dim
    /// printed URL under a link, inline code, fenced code text, the
    /// fence border glyphs, quoted text, the quote rail, horizontal
    /// rules and list bullets.
    this.mdHeading = const Style(),
    this.mdLink = const Style(),
    this.mdLinkUrl = const Style(),
    this.mdCode = const Style(),
    this.mdCodeBlock = const Style(),
    this.mdCodeBlockBorder = const Style(),
    this.mdQuote = const Style(),
    this.mdQuoteBorder = const Style(),
    this.mdHr = const Style(),
    this.mdListBullet = const Style(),

    /// Bare link foreground (non-markdown contexts).
    this.link = const Style(),

    /// Diff text roles (S2/S4 tool cards): added/removed lines and the
    /// dim context lines.
    this.toolDiffAdded = const Style(),
    this.toolDiffRemoved = const Style(),
    this.toolDiffContext = const Style(),

    /// Syntax highlighting (S5), VS Code Dark+/Light+ token sets.
    this.syntaxComment = const Style(),
    this.syntaxKeyword = const Style(),
    this.syntaxFunction = const Style(),
    this.syntaxVariable = const Style(),
    this.syntaxString = const Style(),
    this.syntaxNumber = const Style(),
    this.syntaxType = const Style(),
    this.syntaxOperator = const Style(),
    this.syntaxPunctuation = const Style(),

    /// Bash-mode / python-mode prompt indicator (S3 composer band).
    this.bashMode = const Style(),
    this.pythonMode = const Style(),

    /// Status line (S2): band background, separator glyphs, and the
    /// segment text roles (model, path, git state, context share,
    /// spend, staged/dirty/untracked counts, output/cost, subagents).
    /// Text roles render over [statusLineBg].
    this.statusLineBg = const Style(),
    this.statusLineSep = const Style(),
    this.statusLineModel = const Style(),
    this.statusLinePath = const Style(),
    this.statusLineGitClean = const Style(),
    this.statusLineGitDirty = const Style(),
    this.statusLineContext = const Style(),
    this.statusLineSpend = const Style(),
    this.statusLineStaged = const Style(),
    this.statusLineDirty = const Style(),
    this.statusLineUntracked = const Style(),
    this.statusLineOutput = const Style(),
    this.statusLineCost = const Style(),
    this.statusLineSubagents = const Style(),
  });

  final String name;

  /// Normal body text.
  final Style base;

  /// Secondary / dimmed text.
  final Style muted;

  /// Active item, cursor, selection highlight foreground.
  final Style accent;

  /// Selected row / active tab background.
  final Style highlight;

  final Style success;
  final Style warning;
  final Style error;

  /// Unfocused container border.
  final Style border;

  /// Focused container border (accent color).
  final Style focusBorder;

  /// Second accent (bold) — tool-call markers, sub-headers. Hosts whose
  /// palette has no second accent leave it unset (renders plain).
  final Style accent2;

  /// The second accent without bold, for wide/dense spans.
  final Style accent2Soft;

  /// Background of echoed user message lines.
  final Style userMessageBg;

  /// Settled/closed row border (dark, quiet).
  final Style borderMuted;

  /// Tool-row label role (the tool name in `✓ bash · cmd`).
  final Style toolTitle;

  /// Tool-row detail/output role (command, path, question text).
  final Style toolOutput;

  /// Foreground of echoed user-message lines.
  final Style userMessageText;

  /// Successful tool row tint (subtle background).
  final Style toolSuccessBg;

  /// Failed tool row tint (subtle background).
  final Style toolErrorBg;

  // ── issue #804 (omp S1) ──────────────────────────────────────────────────

  /// Pending tool row tint (subtle background).
  final Style toolPendingBg;

  /// Background of custom (slash-command) message lines.
  final Style customMessageBg;

  /// Foreground of custom message text over [customMessageBg].
  final Style customMessageText;

  /// Thinking-block body text.
  final Style thinkingText;

  /// Thinking intensity scale, faint → vivid.
  final Style thinkingOff;
  final Style thinkingMinimal;
  final Style thinkingLow;
  final Style thinkingMedium;
  final Style thinkingHigh;
  final Style thinkingXhigh;

  /// Markdown transcript roles (S5).
  final Style mdHeading;
  final Style mdLink;
  final Style mdLinkUrl;
  final Style mdCode;
  final Style mdCodeBlock;
  final Style mdCodeBlockBorder;
  final Style mdQuote;
  final Style mdQuoteBorder;
  final Style mdHr;
  final Style mdListBullet;

  /// Bare link foreground (non-markdown contexts).
  final Style link;

  /// Diff text roles (S2/S4 tool cards).
  final Style toolDiffAdded;
  final Style toolDiffRemoved;
  final Style toolDiffContext;

  /// Syntax highlighting (S5), VS Code Dark+/Light+ token sets.
  final Style syntaxComment;
  final Style syntaxKeyword;
  final Style syntaxFunction;
  final Style syntaxVariable;
  final Style syntaxString;
  final Style syntaxNumber;
  final Style syntaxType;
  final Style syntaxOperator;
  final Style syntaxPunctuation;

  /// Bash-mode / python-mode prompt indicator (S3 composer band).
  final Style bashMode;
  final Style pythonMode;

  /// Status line band + segment roles (S2); text renders over
  /// [statusLineBg].
  final Style statusLineBg;
  final Style statusLineSep;
  final Style statusLineModel;
  final Style statusLinePath;
  final Style statusLineGitClean;
  final Style statusLineGitDirty;
  final Style statusLineContext;
  final Style statusLineSpend;
  final Style statusLineStaged;
  final Style statusLineDirty;
  final Style statusLineUntracked;
  final Style statusLineOutput;
  final Style statusLineCost;
  final Style statusLineSubagents;

  // ── Built-in themes ──────────────────────────────────────────────────────

  /// Catppuccin Mocha — dark, soft purples. This is the default theme used
  /// by all component `*.defaults` style constants.
  static const TuiTheme catppuccin = TuiTheme(
    name: 'catppuccin',
    base: Style(
      foregroundRgb: RgbColor(205, 214, 244), // #CDD6F4 Text
      backgroundRgb: RgbColor(30, 30, 46), // #1E1E2E Base
    ),
    muted: Style(
      foregroundRgb: RgbColor(166, 173, 200), // #A6ADC8 Subtext0
      isDim: true,
    ),
    accent: Style(
      foregroundRgb: RgbColor(203, 166, 247), // #CBA6F7 Mauve
      isBold: true,
    ),
    highlight: Style(
      backgroundRgb: RgbColor(49, 50, 68), // #313244 Surface0
    ),
    success: Style(foregroundRgb: RgbColor(166, 227, 161)), // #A6E3A1 Green
    warning: Style(foregroundRgb: RgbColor(249, 226, 175)), // #F9E2AF Yellow
    error: Style(foregroundRgb: RgbColor(243, 139, 168)), // #F38BA8 Red
    border: Style(
      foregroundRgb: RgbColor(88, 91, 112), // #585B70 Surface2
      border: Border.rounded,
    ),
    focusBorder: Style(
      foregroundRgb: RgbColor(203, 166, 247), // #CBA6F7 Mauve
      border: Border.rounded,
    ),
    accent2: Style(
      foregroundRgb: RgbColor(137, 180, 250), // #89B4FA Blue
      isBold: true,
    ),
    accent2Soft: Style(foregroundRgb: RgbColor(137, 180, 250)), // #89B4FA
    userMessageBg: Style(
      backgroundRgb: RgbColor(24, 24, 37), // #181825 Mantle
    ),
    borderMuted: Style(
      foregroundRgb: RgbColor(88, 91, 112), // #585B70 Surface2
      isDim: true,
    ),
    toolTitle: Style(
      foregroundRgb: RgbColor(137, 180, 250), // #89B4FA Blue
      isBold: true,
    ),
    toolOutput: Style(
      foregroundRgb: RgbColor(166, 173, 200), // #A6ADC8 Subtext0
      isDim: true,
    ),
    userMessageText: Style(foregroundRgb: RgbColor(205, 214, 244)), // Text
    toolSuccessBg: Style(backgroundRgb: RgbColor(35, 48, 40)),
    toolErrorBg: Style(backgroundRgb: RgbColor(58, 42, 48)),
  );

  /// Nord — cool arctic blues.
  static const TuiTheme nord = TuiTheme(
    name: 'nord',
    base: Style(
      foregroundRgb: RgbColor(236, 239, 244), // #ECEFF4 Nord6
      backgroundRgb: RgbColor(46, 52, 64), // #2E3440 Nord0
    ),
    // gh-671 readability: Nord3 (#4C566A) is 2.24:1 on a dark terminal —
    // secondary text lightened to the Nord3/4 midpoint, dim flag kept.
    muted: Style(
      foregroundRgb: RgbColor(135, 146, 168), // #8792A8
      isDim: true,
    ),
    accent: Style(
      foregroundRgb: RgbColor(136, 192, 208), // #88C0D0 Nord8 Frost
      isBold: true,
    ),
    highlight: Style(
      backgroundRgb: RgbColor(59, 66, 82), // #3B4252 Nord1
    ),
    success: Style(foregroundRgb: RgbColor(163, 190, 140)), // #A3BE8C Nord14
    warning: Style(foregroundRgb: RgbColor(235, 203, 139)), // #EBCB8B Nord13
    error: Style(foregroundRgb: RgbColor(191, 97, 106)), // #BF616A Nord11
    border: Style(
      foregroundRgb: RgbColor(76, 86, 106), // #4C566A Nord3
      border: Border.box,
    ),
    focusBorder: Style(
      foregroundRgb: RgbColor(136, 192, 208), // #88C0D0 Nord8
      border: Border.box,
    ),
    accent2: Style(
      foregroundRgb: RgbColor(129, 161, 193), // #81A1C1 Nord9
      isBold: true,
    ),
    accent2Soft: Style(foregroundRgb: RgbColor(129, 161, 193)), // #81A1C1
    userMessageBg: Style(
      backgroundRgb: RgbColor(59, 66, 82), // #3B4252 Nord1
    ),
    borderMuted: Style(
      foregroundRgb: RgbColor(76, 86, 106), // #4C566A Nord3
      isDim: true,
    ),
    toolTitle: Style(
      foregroundRgb: RgbColor(129, 161, 193), // #81A1C1 Nord9
      isBold: true,
    ),
    // gh-671 readability: Nord3 (#4C566A) is 1.5:1 over the tool tints and
    // 2.2:1 on a dark terminal — detail text lightened to the Nord3/4
    // midpoint, dim flag kept for the muted look on unpainted rows.
    toolOutput: Style(
      foregroundRgb: RgbColor(160, 170, 192), // #A0AAC0
      isDim: true,
    ),
    userMessageText: Style(foregroundRgb: RgbColor(236, 239, 244)), // Nord6
    toolSuccessBg: Style(backgroundRgb: RgbColor(51, 61, 56)),
    // gh-671 readability: darkened so the #BF616A error rail clears 3:1
    // (was 2.87:1 on the old tint).
    toolErrorBg: Style(backgroundRgb: RgbColor(48, 36, 42)),
  );

  /// Dracula — vivid purples and vibrant accents.
  static const TuiTheme dracula = TuiTheme(
    name: 'dracula',
    base: Style(
      foregroundRgb: RgbColor(248, 248, 242), // #F8F8F2 Foreground
      backgroundRgb: RgbColor(40, 42, 54), // #282A36 Background
    ),
    muted: Style(
      foregroundRgb: RgbColor(98, 114, 164), // #6272A4 Comment
      isDim: true,
    ),
    accent: Style(
      foregroundRgb: RgbColor(189, 147, 249), // #BD93F9 Purple
      isBold: true,
    ),
    highlight: Style(
      backgroundRgb: RgbColor(68, 71, 90), // #44475A Current Line
    ),
    success: Style(foregroundRgb: RgbColor(80, 250, 123)), // #50FA7B Green
    warning: Style(foregroundRgb: RgbColor(255, 184, 108)), // #FFB86C Orange
    error: Style(foregroundRgb: RgbColor(255, 85, 85)), // #FF5555 Red
    border: Style(
      foregroundRgb: RgbColor(98, 114, 164), // #6272A4 Comment
      border: Border.rounded,
    ),
    focusBorder: Style(
      foregroundRgb: RgbColor(189, 147, 249), // #BD93F9 Purple
      border: Border.rounded,
    ),
    accent2: Style(
      foregroundRgb: RgbColor(139, 233, 253), // #8BE9FD Cyan
      isBold: true,
    ),
    accent2Soft: Style(foregroundRgb: RgbColor(139, 233, 253)), // #8BE9FD
    userMessageBg: Style(
      backgroundRgb: RgbColor(33, 34, 44), // #21222C
    ),
    borderMuted: Style(
      foregroundRgb: RgbColor(98, 114, 164), // #6272A4 Comment
      isDim: true,
    ),
    toolTitle: Style(
      foregroundRgb: RgbColor(139, 233, 253), // #8BE9FD Cyan
      isBold: true,
    ),
    // gh-671 readability: Comment (#6272A4) is 2.6:1 over the tool tints —
    // detail text lightened within the comment-lavender family, dim flag
    // kept for the muted look on unpainted rows.
    toolOutput: Style(
      foregroundRgb: RgbColor(155, 163, 204), // #9BA3CC
      isDim: true,
    ),
    userMessageText: Style(foregroundRgb: RgbColor(248, 248, 242)), // F8F8F2
    toolSuccessBg: Style(backgroundRgb: RgbColor(40, 56, 46)),
    toolErrorBg: Style(backgroundRgb: RgbColor(62, 40, 48)),
  );

  /// Alias for [catppuccin] — the default theme applied to all component styles.
  static const TuiTheme defaultTheme = catppuccin;
}
