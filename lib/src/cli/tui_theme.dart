/// The session-current TUI theme (issue #279): built-in palettes, ports of
/// oh-my-pi's `dark`/`light` and pi's `dark`, user themes from
/// `~/.fah/themes/<name>.json`, runtime switching via `/theme`, and
/// persistence via the `tui.theme` config key.
///
/// Every color the CLI TUI emits flows through [FaThemeController.current]
/// at render time, so a switch repaints the whole surface with the next
/// frame (the differential renderer keeps the swap frame-atomic and only
/// repaints palette-dependent cells). The default theme reproduces the
/// historical site palette BYTE-IDENTICALLY in truecolor — nothing changes
/// visually until the user switches.
///
/// Role mapping from the oh-my-pi/pi JSON formats (documented in PR #279):
///
/// | our role       | their key              |
/// |----------------|------------------------|
/// | accent         | accent                 |
/// | accent2/2Soft  | customMessageLabel     |
/// | muted          | dim (+ faint)          |
/// | highlight      | selectedBg             |
/// | border         | border                 |
/// | focusBorder    | borderAccent           |
/// | success        | success                |
/// | warning        | warning                |
/// | error          | error                  |
/// | userMessageBg  | userMessageBg          |
///
/// The #444 completion adds borderMuted, toolTitle, toolOutput,
/// userMessageText and the toolSuccessBg/toolErrorBg tints. Issue #804
/// completes the ohmypi-dark/light ports to FULL token parity with the
/// pinned fixture under `test/fixtures/tui_omp/` (statusLine*, syntax*,
/// thinking scale, md*, diffs, mode indicators — the parity walker in
/// `tui_theme_test.dart` walks every token; deliberate WCAG deviations
/// are allowlisted there), adds the symbol presets (`tui_symbols.dart`),
/// and the auto light/dark detection tier on [FaThemeController].
/// User themes use OUR role schema, so nothing silently drops.
library;

import 'dart:convert';
import 'dart:math' as math;

// The PURE entry point: the barrel (dart_tui.dart) drags in
// program/windows_terminal -> dart:ffi, which the web build cannot
// compile (fa_tui_stub -> tui_prompt -> tui_theme ships to web). The
// hosted package has no pure entry point (the vendored fork's
// lib/style.dart shim is local-only, never published), so import the
// pure source files directly — the very libraries the fork's shim
// re-exports, and the same libraries the barrel exports for the VM-only
// TUI code, so types stay identical across both resolutions.
// ponytail: these src/ paths are not semver-covered; the fork patches
// these exact files and 2.0.0→2.1.0 kept them stable. Revisit if
// upstream moves them (then: propose the pure shim upstream).
import 'package:dart_tui/src/bubbles/style.dart' show RgbColor, Style;
import 'tui_symbols.dart';
import 'tui_theme_palette.dart';

/// The fah-owned palette type (see tui_theme_palette.dart): the hosted
/// dart_tui `Theme` lacks the #444 roles, so fah vendors its extension.
export 'tui_theme_palette.dart';

/// The symbol presets (issue #804): glyphs + spinner frames, keyed like
/// omp's symbol map.
export 'tui_symbols.dart';

/// The vendor color profile ([FaThemeController.profile]'s type) is part
/// of this file's public API surface — consumers theme through here, not
/// through the vendored TUI package.
export 'package:dart_tui/src/msg.dart' show ColorProfile;
import 'package:dart_tui/src/msg.dart' show ColorProfile;
import 'tool_rows.dart' show LaidOutToolRow, ToolRowState;
import 'tui_repl.dart' show MenuItem;

// The gh-671 readability contract: floors every built-in palette must
// clear for the pairs the emitters actually paint. Body/detail text over
// a theme-painted background clears WCAG AA (4.5:1); secondary text and
// bold labels over the reference terminal clear 3:1; the user band keeps
// the issue-#444 7:1 floor.

/// Contrast floor for detail/body text painted over a theme background.
const double kThemeBodyTextFloor = 4.5;

/// Contrast floor for secondary text (muted) and bold labels on the
/// reference terminal, and for the non-text state rails over their tints.
const double kThemeSecondaryTextFloor = 3.0;

/// Contrast floor of the echoed user-message band (issue #444 defect 4).
const double kThemeUserMessageFloor = 7.0;

/// The boot default: the historical site palette (site/styles.css teal +
/// indigo). Since gh-671 dim detail text carries an explicit `toolOutput`
/// foreground (the old byte-identical-to-pre-theming invariant is
/// deliberately broken — see `tui_theme_default.ans`).
const TuiTheme kDefaultTuiTheme = TuiTheme(
  name: 'default',
  base: Style(),
  muted: Style(isDim: true),
  accent: Style(
    foregroundRgb: RgbColor(94, 234, 212), // #5EEAD4 site teal
    isBold: true,
  ),
  highlight: Style(backgroundRgb: RgbColor(49, 50, 68)),
  success: Style(foregroundRgb: RgbColor(74, 222, 128)), // #4ADE80
  warning: Style(foregroundRgb: RgbColor(250, 204, 21)), // #FACC15
  error: Style(foregroundRgb: RgbColor(248, 113, 113)), // #F87171
  border: Style(isDim: true),
  focusBorder: Style(
    foregroundRgb: RgbColor(94, 234, 212), // #5EEAD4
  ),
  accent2: Style(
    foregroundRgb: RgbColor(129, 140, 248), // #818CF8 site indigo
    isBold: true,
  ),
  accent2Soft: Style(foregroundRgb: RgbColor(129, 140, 248)), // #818CF8
  userMessageBg: Style(backgroundRgb: RgbColor(30, 34, 42)), // #1E222A
  // Issue #444 role-table completion: every rendered string picks a
  // named role; a missing role renders plain text, never a color pick.
  borderMuted: Style(isDim: true),
  toolTitle: Style(
    foregroundRgb: RgbColor(129, 140, 248), // #818CF8
    isBold: true,
  ),
  // gh-671: an explicit detail foreground — dim-only text over the dark
  // tints and the terminal relied on the (unpainted, unknown) default fg.
  toolOutput: Style(foregroundRgb: RgbColor(0xB8, 0xC2, 0xCE), isDim: true),
  userMessageText: Style(foregroundRgb: RgbColor(0xE8, 0xEE, 0xF7)),
  toolSuccessBg: Style(backgroundRgb: RgbColor(20, 37, 27)),
  toolErrorBg: Style(backgroundRgb: RgbColor(42, 21, 24)),
);

/// The built-in catalog, keyed by config name. `default` wins the
/// `default` alias; every other name resolves literally.
const Map<String, TuiTheme> kBuiltInTuiThemes = {
  'default': kDefaultTuiTheme,
  'catppuccin': TuiTheme.catppuccin,
  'nord': TuiTheme.nord,
  'dracula': TuiTheme.dracula,
  'ohmypi-dark': _ohmypiDark,
  'ohmypi-light': _ohmypiLight,
  'pi': _piDark,
};

/// oh-my-pi `dark.json` port (vars resolved; see the library-docs mapping).
/// Complete token parity with the pinned fixture
/// (`test/fixtures/tui_omp/dark.json`, omp df624f5) — the parity walker in
/// `tui_theme_test.dart` asserts every token. Deviations tagged gh-671/#804
/// with the reason; 256-color palette indexes resolve to their RGB cube or
/// grayscale value (noted inline) so the vendor's ansi256 quantization
/// round-trips them exactly.
const TuiTheme _ohmypiDark = TuiTheme(
  name: 'ohmypi-dark',
  base: Style(),
  // gh-671 readability: #5f6673 (their dark.json `dim`) is 2.86:1 on a
  // dark terminal — lightened one step, same family, dim flag kept.
  muted: Style(foregroundRgb: RgbColor(0x86, 0x8d, 0x99), isDim: true),
  accent: Style(foregroundRgb: RgbColor(0xfe, 0xbc, 0x38), isBold: true),
  highlight: Style(backgroundRgb: RgbColor(0x31, 0x36, 0x3f)),
  success: Style(foregroundRgb: RgbColor(0x89, 0xd2, 0x81)),
  warning: Style(foregroundRgb: RgbColor(0xe4, 0xc0, 0x0f)),
  error: Style(foregroundRgb: RgbColor(0xfc, 0x3a, 0x4b)),
  border: Style(foregroundRgb: RgbColor(0x17, 0x8f, 0xb9)),
  focusBorder: Style(foregroundRgb: RgbColor(0x00, 0x88, 0xfa)),
  accent2: Style(foregroundRgb: RgbColor(0xb2, 0x81, 0xd6), isBold: true),
  accent2Soft: Style(foregroundRgb: RgbColor(0xb2, 0x81, 0xd6)),
  userMessageBg: Style(backgroundRgb: RgbColor(0x22, 0x1d, 0x1a)),
  // #804 parity: omp `borderMuted` is the darkGray var (#3d424a); the old
  // port shipped dimGray. Decorative border role — omp value verbatim.
  borderMuted: Style(foregroundRgb: RgbColor(0x3d, 0x42, 0x4a), isDim: true),
  // omp ships `toolTitle: ''` (terminal default); fa's #444 role table
  // gives every rendered string a named role — the label keeps accent2.
  toolTitle: Style(foregroundRgb: RgbColor(0xb2, 0x81, 0xd6), isBold: true),
  // gh-671 readability: #777d88 (their `toolOutput` gray) is fine on the
  // reference terminal but the port keeps the lightened family gray for
  // AA on the tints.
  toolOutput: Style(foregroundRgb: RgbColor(0x86, 0x8d, 0x99), isDim: true),
  // omp ships `userMessageText: ''`; explicit per the gh-671 contract
  // (text over a painted band never relies on the terminal default).
  userMessageText: Style(foregroundRgb: RgbColor(0xd4, 0xd4, 0xd4)),
  // #804 parity: omp tints verbatim (the old greenish/reddish ports
  // predate the audit; rails keep ≥3:1 on these, floors re-verified).
  toolSuccessBg: Style(backgroundRgb: RgbColor(0x16, 0x1a, 0x1f)),
  toolErrorBg: Style(backgroundRgb: RgbColor(0x29, 0x1d, 0x1d)),
  toolPendingBg: Style(backgroundRgb: RgbColor(0x1d, 0x21, 0x29)),
  customMessageBg: Style(backgroundRgb: RgbColor(0x2a, 0x25, 0x30)),
  customMessageText: Style(foregroundRgb: RgbColor(0xd4, 0xd4, 0xd4)),
  // gh-671 readability: omp's #777d88 thinking prose is 3.97:1 on the
  // reference terminal — below the 4.5:1 body floor (review k6LLp);
  // lifted to the lightened family gray like [muted]/[toolOutput].
  thinkingText: Style(foregroundRgb: RgbColor(0x86, 0x8d, 0x99)),
  // Thinking scale: omp's two faintest steps (#3d424a darkGray 1.6:1 and
  // #5f6673 dimGray 2.9:1) fail the 3:1 secondary floor on a dark
  // terminal — lifted to the palette's own gray family, scale order kept.
  thinkingOff: Style(foregroundRgb: RgbColor(0x77, 0x7d, 0x88)),
  thinkingMinimal: Style(foregroundRgb: RgbColor(0x86, 0x8d, 0x99)),
  thinkingLow: Style(foregroundRgb: RgbColor(0x17, 0x8f, 0xb9)),
  thinkingMedium: Style(foregroundRgb: RgbColor(0x00, 0x88, 0xfa)),
  thinkingHigh: Style(foregroundRgb: RgbColor(0xb2, 0x81, 0xd6)),
  thinkingXhigh: Style(foregroundRgb: RgbColor(0xe5, 0xc1, 0xff)),
  mdHeading: Style(foregroundRgb: RgbColor(0xfe, 0xbc, 0x38)),
  mdLink: Style(foregroundRgb: RgbColor(0x00, 0x88, 0xfa)),
  // gh-671 readability: #5f6673 dimGray link URLs are 2.9:1 — lifted to
  // the lightened family gray like [muted].
  mdLinkUrl: Style(foregroundRgb: RgbColor(0x86, 0x8d, 0x99)),
  mdCode: Style(foregroundRgb: RgbColor(0xe5, 0xc1, 0xff)),
  mdCodeBlock: Style(foregroundRgb: RgbColor(0x9c, 0xdc, 0xfe)),
  mdCodeBlockBorder: Style(foregroundRgb: RgbColor(0x77, 0x7d, 0x88)),
  mdQuote: Style(foregroundRgb: RgbColor(0x77, 0x7d, 0x88)),
  mdQuoteBorder: Style(foregroundRgb: RgbColor(0x3d, 0x42, 0x4a)),
  mdHr: Style(foregroundRgb: RgbColor(0x3d, 0x42, 0x4a)),
  mdListBullet: Style(foregroundRgb: RgbColor(0xfe, 0xbc, 0x38)),
  link: Style(foregroundRgb: RgbColor(0x00, 0x88, 0xfa)),
  toolDiffAdded: Style(foregroundRgb: RgbColor(0x89, 0xd2, 0x81)),
  toolDiffRemoved: Style(foregroundRgb: RgbColor(0xfc, 0x3a, 0x4b)),
  toolDiffContext: Style(foregroundRgb: RgbColor(0x77, 0x7d, 0x88)),
  syntaxComment: Style(foregroundRgb: RgbColor(0x6a, 0x99, 0x55)),
  syntaxKeyword: Style(foregroundRgb: RgbColor(0x56, 0x9c, 0xd6)),
  syntaxFunction: Style(foregroundRgb: RgbColor(0xdc, 0xdc, 0xaa)),
  syntaxVariable: Style(foregroundRgb: RgbColor(0x9c, 0xdc, 0xfe)),
  syntaxString: Style(foregroundRgb: RgbColor(0xce, 0x91, 0x78)),
  syntaxNumber: Style(foregroundRgb: RgbColor(0xb5, 0xce, 0xa8)),
  syntaxType: Style(foregroundRgb: RgbColor(0x4e, 0xc9, 0xb0)),
  syntaxOperator: Style(foregroundRgb: RgbColor(0xd4, 0xd4, 0xd4)),
  syntaxPunctuation: Style(foregroundRgb: RgbColor(0xd4, 0xd4, 0xd4)),
  bashMode: Style(foregroundRgb: RgbColor(0x00, 0x88, 0xfa)),
  pythonMode: Style(foregroundRgb: RgbColor(0xe4, 0xc0, 0x0f)),
  statusLineBg: Style(backgroundRgb: RgbColor(0x12, 0x12, 0x12)),
  statusLineSep: Style(foregroundRgb: RgbColor(0x80, 0x80, 0x80)), // 256:244
  statusLineModel: Style(foregroundRgb: RgbColor(0xd7, 0x87, 0xaf)),
  statusLinePath: Style(foregroundRgb: RgbColor(0x00, 0xaf, 0xaf)),
  statusLineGitClean: Style(foregroundRgb: RgbColor(0x5f, 0xaf, 0x5f)),
  statusLineGitDirty: Style(foregroundRgb: RgbColor(0xd7, 0xaf, 0x5f)),
  statusLineContext: Style(foregroundRgb: RgbColor(0x87, 0x87, 0xaf)),
  statusLineSpend: Style(foregroundRgb: RgbColor(0x5f, 0xaf, 0xaf)),
  statusLineStaged: Style(foregroundRgb: RgbColor(0x5f, 0xaf, 0x00)), // 256:70
  statusLineDirty: Style(foregroundRgb: RgbColor(0xd7, 0xaf, 0x00)), // 256:178
  statusLineUntracked: Style(
    foregroundRgb: RgbColor(0x00, 0xaf, 0xff),
  ), // 256:39
  statusLineOutput: Style(foregroundRgb: RgbColor(0xff, 0x5f, 0xaf)), // 256:205
  statusLineCost: Style(foregroundRgb: RgbColor(0xff, 0x5f, 0xaf)), // 256:205
  statusLineSubagents: Style(foregroundRgb: RgbColor(0xfe, 0xbc, 0x38)),
);

/// oh-my-pi `light.json` port — complete token parity with the pinned
/// fixture (`test/fixtures/tui_omp/light.json`), same deviation rules as
/// [_ohmypiDark].
const TuiTheme _ohmypiLight = TuiTheme(
  name: 'ohmypi-light',
  base: Style(),
  // omp `muted` is their mediumGray #6c6c6c; the port keeps the darkGray
  // #767676 step (the pre-audit choice, 4.5:1 on white) — allowlisted.
  muted: Style(foregroundRgb: RgbColor(0x76, 0x76, 0x76), isDim: true),
  accent: Style(foregroundRgb: RgbColor(0x5a, 0x80, 0x80), isBold: true),
  highlight: Style(backgroundRgb: RgbColor(0xd0, 0xd0, 0xe0)),
  success: Style(foregroundRgb: RgbColor(0x58, 0x84, 0x58)),
  warning: Style(foregroundRgb: RgbColor(0x9a, 0x73, 0x26)),
  error: Style(foregroundRgb: RgbColor(0xaa, 0x55, 0x55)),
  border: Style(foregroundRgb: RgbColor(0x54, 0x7d, 0xa7)),
  focusBorder: Style(foregroundRgb: RgbColor(0x5a, 0x80, 0x80)),
  accent2: Style(foregroundRgb: RgbColor(0x7e, 0x57, 0xc2), isBold: true),
  accent2Soft: Style(foregroundRgb: RgbColor(0x7e, 0x57, 0xc2)),
  userMessageBg: Style(backgroundRgb: RgbColor(0xe8, 0xe8, 0xe8)),
  // #804 parity: omp `borderMuted` is the lightGray var (#b0b0b0).
  borderMuted: Style(foregroundRgb: RgbColor(0xb0, 0xb0, 0xb0), isDim: true),
  toolTitle: Style(foregroundRgb: RgbColor(0x7e, 0x57, 0xc2), isBold: true),
  // gh-671 readability: #767676 is 3.5:1 on the light tints — darkened so
  // detail text clears AA on the palette's own reference terminal.
  toolOutput: Style(foregroundRgb: RgbColor(0x56, 0x56, 0x56), isDim: true),
  userMessageText: Style(foregroundRgb: RgbColor(0x22, 0x22, 0x22)),
  toolSuccessBg: Style(backgroundRgb: RgbColor(0xe8, 0xf0, 0xe8)),
  toolErrorBg: Style(backgroundRgb: RgbColor(0xf0, 0xe8, 0xe8)),
  toolPendingBg: Style(backgroundRgb: RgbColor(0xe8, 0xe8, 0xf0)),
  customMessageBg: Style(backgroundRgb: RgbColor(0xed, 0xe7, 0xf6)),
  customMessageText: Style(foregroundRgb: RgbColor(0x22, 0x22, 0x22)),
  thinkingText: Style(foregroundRgb: RgbColor(0x6c, 0x6c, 0x6c)),
  // gh-671-family fix: omp's thinkingOff lightGray (#b0b0b0) is 2.2:1 on
  // white — lifted to the dimGray/lightGray midpoint (3.4:1), scale order
  // kept.
  thinkingOff: Style(foregroundRgb: RgbColor(0x8c, 0x8c, 0x8c)),
  thinkingMinimal: Style(foregroundRgb: RgbColor(0x76, 0x76, 0x76)),
  thinkingLow: Style(foregroundRgb: RgbColor(0x54, 0x7d, 0xa7)),
  thinkingMedium: Style(foregroundRgb: RgbColor(0x5a, 0x80, 0x80)),
  thinkingHigh: Style(foregroundRgb: RgbColor(0x87, 0x5f, 0x87)),
  thinkingXhigh: Style(foregroundRgb: RgbColor(0x8b, 0x00, 0x8b)),
  mdHeading: Style(foregroundRgb: RgbColor(0x9a, 0x73, 0x26)),
  mdLink: Style(foregroundRgb: RgbColor(0x54, 0x7d, 0xa7)),
  mdLinkUrl: Style(foregroundRgb: RgbColor(0x76, 0x76, 0x76)),
  mdCode: Style(foregroundRgb: RgbColor(0x5a, 0x80, 0x80)),
  mdCodeBlock: Style(foregroundRgb: RgbColor(0x58, 0x84, 0x58)),
  mdCodeBlockBorder: Style(foregroundRgb: RgbColor(0x6c, 0x6c, 0x6c)),
  mdQuote: Style(foregroundRgb: RgbColor(0x6c, 0x6c, 0x6c)),
  mdQuoteBorder: Style(foregroundRgb: RgbColor(0x6c, 0x6c, 0x6c)),
  mdHr: Style(foregroundRgb: RgbColor(0x6c, 0x6c, 0x6c)),
  mdListBullet: Style(foregroundRgb: RgbColor(0x58, 0x84, 0x58)),
  link: Style(foregroundRgb: RgbColor(0x54, 0x7d, 0xa7)),
  toolDiffAdded: Style(foregroundRgb: RgbColor(0x58, 0x84, 0x58)),
  toolDiffRemoved: Style(foregroundRgb: RgbColor(0xaa, 0x55, 0x55)),
  toolDiffContext: Style(foregroundRgb: RgbColor(0x6c, 0x6c, 0x6c)),
  syntaxComment: Style(foregroundRgb: RgbColor(0x00, 0x80, 0x00)),
  syntaxKeyword: Style(foregroundRgb: RgbColor(0x00, 0x00, 0xff)),
  syntaxFunction: Style(foregroundRgb: RgbColor(0x79, 0x5e, 0x26)),
  syntaxVariable: Style(foregroundRgb: RgbColor(0x00, 0x10, 0x80)),
  syntaxString: Style(foregroundRgb: RgbColor(0xa3, 0x15, 0x15)),
  syntaxNumber: Style(foregroundRgb: RgbColor(0x09, 0x86, 0x58)),
  syntaxType: Style(foregroundRgb: RgbColor(0x26, 0x7f, 0x99)),
  syntaxOperator: Style(foregroundRgb: RgbColor(0x00, 0x00, 0x00)),
  syntaxPunctuation: Style(foregroundRgb: RgbColor(0x00, 0x00, 0x00)),
  bashMode: Style(foregroundRgb: RgbColor(0x58, 0x84, 0x58)),
  pythonMode: Style(foregroundRgb: RgbColor(0x9a, 0x73, 0x26)),
  statusLineBg: Style(backgroundRgb: RgbColor(0xe0, 0xe0, 0xe0)),
  // #804 readability: omp's #808080 separator is 2.99:1 on its own
  // #e0e0e0 band — one step darker inside the palette's grays (3.98:1).
  statusLineSep: Style(foregroundRgb: RgbColor(0x6c, 0x6c, 0x6c)),
  statusLineModel: Style(foregroundRgb: RgbColor(0x87, 0x5f, 0x87)),
  statusLinePath: Style(foregroundRgb: RgbColor(0x00, 0x5f, 0x87)),
  statusLineGitClean: Style(foregroundRgb: RgbColor(0x00, 0x5f, 0x00)),
  statusLineGitDirty: Style(foregroundRgb: RgbColor(0xaf, 0x5f, 0x00)),
  statusLineContext: Style(foregroundRgb: RgbColor(0x5f, 0x5f, 0x87)),
  statusLineSpend: Style(foregroundRgb: RgbColor(0x00, 0x5f, 0x5f)),
  // #804 readability: omp's bright 256-index counts (28 #00d700, 136
  // #afd700, 31 #00afaf) are 1.0–2.7:1 on the light band — re-tinted to
  // the palette's own green/yellow/teal vars (≥3.1:1). Output/cost keep
  // 133 (#af5faf, 3.1:1) verbatim.
  statusLineStaged: Style(foregroundRgb: RgbColor(0x58, 0x84, 0x58)),
  statusLineDirty: Style(foregroundRgb: RgbColor(0x9a, 0x73, 0x26)),
  statusLineUntracked: Style(foregroundRgb: RgbColor(0x5a, 0x80, 0x80)),
  statusLineOutput: Style(foregroundRgb: RgbColor(0xaf, 0x5f, 0xaf)), // 256:133
  statusLineCost: Style(foregroundRgb: RgbColor(0xaf, 0x5f, 0xaf)), // 256:133
  statusLineSubagents: Style(foregroundRgb: RgbColor(0x5a, 0x80, 0x80)),
);

/// pi's interactive-mode dark palette (`theme/dark.json`) port.
const TuiTheme _piDark = TuiTheme(
  name: 'pi',
  base: Style(foregroundRgb: RgbColor(0xd4, 0xd4, 0xd4)),
  // gh-671 readability: #666666 is 2.88:1 on a dark terminal and 2.4:1 on
  // the tints — lightened one step, dim flag kept.
  muted: Style(foregroundRgb: RgbColor(0x98, 0x98, 0x98), isDim: true),
  accent: Style(foregroundRgb: RgbColor(0x8a, 0xbe, 0xb7), isBold: true),
  highlight: Style(backgroundRgb: RgbColor(0x3a, 0x3a, 0x4a)),
  success: Style(foregroundRgb: RgbColor(0xb5, 0xbd, 0x68)),
  warning: Style(foregroundRgb: RgbColor(0xff, 0xff, 0x00)),
  error: Style(foregroundRgb: RgbColor(0xcc, 0x66, 0x66)),
  border: Style(foregroundRgb: RgbColor(0x5f, 0x87, 0xff)),
  focusBorder: Style(foregroundRgb: RgbColor(0x00, 0xd7, 0xff)),
  accent2: Style(foregroundRgb: RgbColor(0x95, 0x75, 0xcd), isBold: true),
  accent2Soft: Style(foregroundRgb: RgbColor(0x95, 0x75, 0xcd)),
  userMessageBg: Style(backgroundRgb: RgbColor(0x34, 0x35, 0x41)),
  borderMuted: Style(foregroundRgb: RgbColor(0x4a, 0x4a, 0x4a), isDim: true),
  toolTitle: Style(foregroundRgb: RgbColor(0x95, 0x75, 0xcd), isBold: true),
  // gh-671 readability: #666666 is 2.4:1 on the tints — lightened.
  toolOutput: Style(foregroundRgb: RgbColor(0x98, 0x98, 0x98), isDim: true),
  userMessageText: Style(foregroundRgb: RgbColor(0xd4, 0xd4, 0xd4)),
  toolSuccessBg: Style(backgroundRgb: RgbColor(0x2a, 0x2e, 0x24)),
  toolErrorBg: Style(backgroundRgb: RgbColor(0x36, 0x26, 0x26)),
);

/// The roles a user theme JSON may set (values: `#rgb`/`#rrggbb`).
const Set<String> kThemeRoleNames = {
  'accent',
  'accent2',
  'accent2Soft',
  'muted',
  'highlight',
  'success',
  'warning',
  'error',
  'border',
  'focusBorder',
  'userMessageBg',
  'borderMuted',
  'toolTitle',
  'toolOutput',
  'userMessageText',
  'toolSuccessBg',
  'toolErrorBg',
  // issue #804: the omp token families (partial themes keep inheriting
  // per-role; built-in names stay unshadowable).
  'toolPendingBg',
  'customMessageBg',
  'customMessageText',
  'thinkingText',
  'thinkingOff',
  'thinkingMinimal',
  'thinkingLow',
  'thinkingMedium',
  'thinkingHigh',
  'thinkingXhigh',
  'mdHeading',
  'mdLink',
  'mdLinkUrl',
  'mdCode',
  'mdCodeBlock',
  'mdCodeBlockBorder',
  'mdQuote',
  'mdQuoteBorder',
  'mdHr',
  'mdListBullet',
  'link',
  'toolDiffAdded',
  'toolDiffRemoved',
  'toolDiffContext',
  'syntaxComment',
  'syntaxKeyword',
  'syntaxFunction',
  'syntaxVariable',
  'syntaxString',
  'syntaxNumber',
  'syntaxType',
  'syntaxOperator',
  'syntaxPunctuation',
  'bashMode',
  'pythonMode',
  'statusLineBg',
  'statusLineSep',
  'statusLineModel',
  'statusLinePath',
  'statusLineGitClean',
  'statusLineGitDirty',
  'statusLineContext',
  'statusLineSpend',
  'statusLineStaged',
  'statusLineDirty',
  'statusLineUntracked',
  'statusLineOutput',
  'statusLineCost',
  'statusLineSubagents',
};

/// A user-theme parse failure naming every problem with its role and line.
final class ThemeParseException implements Exception {
  ThemeParseException(this.problems);
  final List<String> problems;

  @override
  String toString() => 'invalid theme: ${problems.join('; ')}';
}

/// Parses one `#rgb`/`#rrggbb` color, returning null on anything else.
RgbColor? _parseHexColor(String value) {
  final hex = value.startsWith('#') ? value.substring(1) : value;
  final digits = int.tryParse(hex, radix: 16);
  if (digits == null) return null;
  switch (hex.length) {
    case 3:
      return RgbColor(
        (digits >> 8 & 0xf) * 17,
        (digits >> 4 & 0xf) * 17,
        (digits & 0xf) * 17,
      );
    case 6:
      return RgbColor(digits >> 16 & 0xff, digits >> 8 & 0xff, digits & 0xff);
    default:
      return null;
  }
}

/// The 1-based line of `"role"` in [text], or 0 when absent (used by named
/// parse errors).
int _roleLine(String text, String role) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].contains('"$role"')) return i + 1;
  }
  return 0;
}

/// Parses a user theme JSON document ([text], named [fileName]): tolerant of
/// missing roles (they inherit the default theme) and naming every problem
/// with its role and line — never a raw crash.
TuiTheme parseUserTheme(String text, String fileName) {
  final Object? doc;
  try {
    doc = jsonDecode(text);
  } on FormatException catch (error) {
    final line = error.offset == null
        ? 0
        : '\n'.allMatches(error.source.substring(0, error.offset)).length + 1;
    throw ThemeParseException(['$fileName: not valid JSON at line $line']);
  }
  if (doc is! Map) {
    throw ThemeParseException(['$fileName: top level must be a JSON object']);
  }
  final rolesNode = doc['roles'] ?? doc['colors'];
  if (rolesNode is! Map) {
    throw ThemeParseException([
      '$fileName: missing "roles" object (${kThemeRoleNames.length} roles: '
          '${kThemeRoleNames.join(', ')})',
    ]);
  }
  final problems = <String>[];
  final resolved = <String, RgbColor>{};
  for (final entry in rolesNode.entries) {
    final role = '${entry.key}';
    if (!kThemeRoleNames.contains(role)) {
      problems.add('$fileName:${_roleLine(text, role)}: unknown role "$role"');
      continue;
    }
    final color = _parseHexColor('${entry.value}');
    if (color == null) {
      problems.add(
        '$fileName:${_roleLine(text, role)}: role "$role" must be '
        '"#rgb" or "#rrggbb", got "${entry.value}"',
      );
      continue;
    }
    resolved[role] = color;
  }
  if (problems.isNotEmpty) throw ThemeParseException(problems);

  // Missing roles inherit the DEFAULT palette (E3): a partial theme
  // overrides only what it names — the rest keeps the default's color
  // and flags (border stays dim, muted stays faint) instead of degrading
  // to unstyled text.
  Style fg(String role, {bool bold = false, bool dim = false}) {
    final defStyle = _defaultRoleStyle(role);
    final color = resolved[role] ?? defStyle?.foregroundRgb;
    if (color == null) return defStyle ?? const Style();
    return Style(
      foregroundRgb: color,
      isBold: bold || (defStyle?.isBold ?? false) ? true : null,
      isDim: dim || (defStyle?.isDim ?? false) ? true : null,
    );
  }

  // Background roles: same inheritance, against the default's background.
  Style bg(String role) => Style(
    backgroundRgb: resolved[role] ?? _defaultRoleStyle(role)?.backgroundRgb,
  );

  return TuiTheme(
    name: fileName,
    base: const Style(),
    accent2Soft: fg('accent2Soft'),
    accent: fg('accent', bold: true),
    accent2: fg('accent2', bold: true),
    muted: fg('muted', dim: true),
    highlight: bg('highlight'),
    success: fg('success'),
    warning: fg('warning'),
    error: fg('error'),
    border: fg('border'),
    focusBorder: fg('focusBorder'),
    userMessageBg: bg('userMessageBg'),
    borderMuted: fg('borderMuted'),
    toolTitle: fg('toolTitle'),
    toolOutput: fg('toolOutput', dim: true),
    userMessageText: fg('userMessageText'),
    toolSuccessBg: bg('toolSuccessBg'),
    toolErrorBg: bg('toolErrorBg'),
    // issue #804 token families: same inheritance rules, no flags (omp
    // has none).
    toolPendingBg: bg('toolPendingBg'),
    customMessageBg: bg('customMessageBg'),
    customMessageText: fg('customMessageText'),
    thinkingText: fg('thinkingText'),
    thinkingOff: fg('thinkingOff'),
    thinkingMinimal: fg('thinkingMinimal'),
    thinkingLow: fg('thinkingLow'),
    thinkingMedium: fg('thinkingMedium'),
    thinkingHigh: fg('thinkingHigh'),
    thinkingXhigh: fg('thinkingXhigh'),
    mdHeading: fg('mdHeading'),
    mdLink: fg('mdLink'),
    mdLinkUrl: fg('mdLinkUrl'),
    mdCode: fg('mdCode'),
    mdCodeBlock: fg('mdCodeBlock'),
    mdCodeBlockBorder: fg('mdCodeBlockBorder'),
    mdQuote: fg('mdQuote'),
    mdQuoteBorder: fg('mdQuoteBorder'),
    mdHr: fg('mdHr'),
    mdListBullet: fg('mdListBullet'),
    link: fg('link'),
    toolDiffAdded: fg('toolDiffAdded'),
    toolDiffRemoved: fg('toolDiffRemoved'),
    toolDiffContext: fg('toolDiffContext'),
    syntaxComment: fg('syntaxComment'),
    syntaxKeyword: fg('syntaxKeyword'),
    syntaxFunction: fg('syntaxFunction'),
    syntaxVariable: fg('syntaxVariable'),
    syntaxString: fg('syntaxString'),
    syntaxNumber: fg('syntaxNumber'),
    syntaxType: fg('syntaxType'),
    syntaxOperator: fg('syntaxOperator'),
    syntaxPunctuation: fg('syntaxPunctuation'),
    bashMode: fg('bashMode'),
    pythonMode: fg('pythonMode'),
    statusLineBg: bg('statusLineBg'),
    statusLineSep: fg('statusLineSep'),
    statusLineModel: fg('statusLineModel'),
    statusLinePath: fg('statusLinePath'),
    statusLineGitClean: fg('statusLineGitClean'),
    statusLineGitDirty: fg('statusLineGitDirty'),
    statusLineContext: fg('statusLineContext'),
    statusLineSpend: fg('statusLineSpend'),
    statusLineStaged: fg('statusLineStaged'),
    statusLineDirty: fg('statusLineDirty'),
    statusLineUntracked: fg('statusLineUntracked'),
    statusLineOutput: fg('statusLineOutput'),
    statusLineCost: fg('statusLineCost'),
    statusLineSubagents: fg('statusLineSubagents'),
  );
}

/// The [role]'s style in the default palette (`null` for roles the
/// default leaves plain).
Style? _defaultRoleStyle(String role) => switch (role) {
  'accent' => kDefaultTuiTheme.accent,
  'accent2' => kDefaultTuiTheme.accent2,
  'accent2Soft' => kDefaultTuiTheme.accent2Soft,
  'muted' => kDefaultTuiTheme.muted,
  'highlight' => kDefaultTuiTheme.highlight,
  'success' => kDefaultTuiTheme.success,
  'warning' => kDefaultTuiTheme.warning,
  'error' => kDefaultTuiTheme.error,
  'border' => kDefaultTuiTheme.border,
  'focusBorder' => kDefaultTuiTheme.focusBorder,
  'userMessageBg' => kDefaultTuiTheme.userMessageBg,
  'borderMuted' => kDefaultTuiTheme.borderMuted,
  'toolTitle' => kDefaultTuiTheme.toolTitle,
  'toolOutput' => kDefaultTuiTheme.toolOutput,
  'userMessageText' => kDefaultTuiTheme.userMessageText,
  'toolSuccessBg' => kDefaultTuiTheme.toolSuccessBg,
  'toolErrorBg' => kDefaultTuiTheme.toolErrorBg,
  _ => null,
};

/// Loads user themes from `<home>/.fah/themes/*.json`. Filenames that
/// shadow a built-in are skipped (user themes can never shadow built-ins);
/// unparseable files are collected into [errors] instead of failing the
/// boot.
({Map<String, TuiTheme> themes, List<String> errors}) loadUserThemes(
  String? homeDir,
  List<String> Function(String dir) listJsonFiles,
  String Function(String path) readFile,
) {
  final themes = <String, TuiTheme>{};
  final errors = <String>[];
  if (homeDir == null || homeDir.isEmpty) {
    return (themes: themes, errors: errors);
  }
  final dir = '$homeDir/.fah/themes';
  for (final path in listJsonFiles(dir)) {
    final name = path.split('/').last.replaceAll(RegExp(r'\.json$'), '');
    if (kBuiltInTuiThemes.containsKey(name)) {
      errors.add(
        '$name: user theme ignored — cannot shadow a built-in theme name',
      );
      continue;
    }
    try {
      themes[name] = parseUserTheme(readFile(path), name);
    } on ThemeParseException catch (error) {
      errors.add(error.toString());
    }
  }
  return (themes: themes, errors: errors);
}

/// Detects the color profile the theme emitters render with. `null` means
/// no styling at all (pipes, `NO_COLOR`, `TERM=dumb`).
ColorProfile? detectThemeProfile({
  required bool ansiSupported,
  Map<String, String> environment = const {},
}) {
  if (!ansiSupported) return null;
  if (environment.containsKey('NO_COLOR')) return null;
  if (environment['TERM'] == 'dumb') return null;
  final colorTerm = environment['COLORTERM'] ?? '';
  if (colorTerm == 'truecolor' || colorTerm == '24bit') {
    return ColorProfile.trueColor;
  }
  if (environment.containsKey('WT_SESSION')) return ColorProfile.trueColor;
  // tmux/screen advertise 256 colors only — degrade instead of guessing.
  if ((environment['TERM'] ?? '').contains('256color')) {
    return ColorProfile.ansi256;
  }
  // Modern default: assume truecolor (matches the pre-theming behavior).
  return ColorProfile.trueColor;
}

/// Owns the session-current theme and renders the TUI color helpers
/// through it. One instance per process ([instance]); tests drive it
/// directly.
final class FaThemeController {
  FaThemeController._();

  /// The process-wide controller the color helpers read.
  static final FaThemeController instance = FaThemeController._();

  TuiTheme _current = kDefaultTuiTheme;
  String _currentName = kDefaultTuiTheme.name;
  final Map<String, TuiTheme> _userThemes = {};

  /// The color profile emitters render with (null = no styling).
  ColorProfile? profile = ColorProfile.trueColor;

  /// The current theme.
  TuiTheme get current => _current;

  /// The current theme's config name.
  String get currentName => _currentName;

  /// All available themes: built-ins first, then user themes (which can
  /// never shadow a built-in name).
  Map<String, TuiTheme> available() => {...kBuiltInTuiThemes, ..._userThemes};

  /// Installs user themes (boot-time; see [loadUserThemes]).
  void addUserThemes(Map<String, TuiTheme> themes) =>
      _userThemes.addAll(themes);

  /// Applies [name] if known; returns whether it resolved. Does not
  /// persist (that is `/theme`'s job). Disarms the auto light/dark tier —
  /// an explicit choice outranks detection for the rest of the session.
  bool switchTo(String name) {
    final theme = available()[name];
    if (theme == null) return false;
    _current = theme;
    _currentName = name;
    _autoArmed = false;
    return true;
  }

  // ── Auto light/dark detection (issue #804) ──────────────────────────────

  bool _autoArmed = false;
  String? _autoColorfgbg;
  RgbColor? _measuredBg;

  /// Whether the boot ran the detection tier (no explicit `tui.theme`);
  /// while armed, a terminal OSC 11 background reply re-resolves the
  /// palette. Any explicit [switchTo] disarms.
  bool get autoLightDarkArmed => _autoArmed;

  /// The terminal background the TUI measured via its OSC 11 query (the
  /// vendored program probes at startup; `fa_tui` feeds the reply here).
  set measuredTerminalBg(RgbColor? rgb) => _measuredBg = rgb;

  /// The detection tier (omp `theme.ts` semantics): a measured terminal
  /// background wins (luminance > 0.5 → light), then `COLORFGBG`
  /// (`fg;bg` — bg ≥ 8 → light), then default dark.
  static bool prefersLightTheme({RgbColor? terminalBg, String? colorfgbg}) {
    if (terminalBg != null) return _relativeLuminance(terminalBg) > 0.5;
    if (colorfgbg != null) {
      final parts = colorfgbg.split(';');
      if (parts.length >= 2) {
        final bg = int.tryParse(parts[1].trim());
        if (bg != null) return bg >= 8;
      }
    }
    return false;
  }

  /// Runs the tier at boot (no explicit `tui.theme`): COLORFGBG is all we
  /// have until the TUI's OSC 11 reply lands. Dark resolves to the
  /// default palette (zero visual change for dark-terminal sessions);
  /// light resolves to `ohmypi-light` — the one palette tuned for light
  /// terminals (gh-671).
  void armAutoLightDark({String? colorfgbg}) {
    _autoArmed = true;
    _autoColorfgbg = colorfgbg;
    _applyAutoTheme();
  }

  /// Re-runs the tier with the measured terminal background; returns
  /// whether the palette changed (the caller hot-swaps). No-op when not
  /// armed.
  bool reapplyAutoLightDark() {
    if (!_autoArmed) return false;
    return _applyAutoTheme();
  }

  bool _applyAutoTheme() {
    final light = prefersLightTheme(
      terminalBg: _measuredBg,
      colorfgbg: _autoColorfgbg,
    );
    final theme = light ? kBuiltInTuiThemes['ohmypi-light']! : kDefaultTuiTheme;
    if (identical(_current, theme)) return false;
    _current = theme;
    _currentName = theme.name;
    return true;
  }

  // ── Symbol presets (issue #804) ─────────────────────────────────────────

  TuiSymbols _symbols = kTuiSymbolsUnicode;

  /// The session symbol preset (glyphs + spinner frames). Consumers go
  /// through [sym] so a preset switch needs no view-code change.
  TuiSymbols get symbols => _symbols;

  /// Applies the symbol preset [name] (`unicode`/`nerd`/`ascii`);
  /// returns whether it resolved.
  bool switchSymbols(String name) {
    final preset = kTuiSymbolPresets[name];
    if (preset == null) return false;
    _symbols = preset;
    return true;
  }

  /// The glyph for the omp symbol [key] in the session preset.
  String sym(String key) => _symbols.glyph(key);

  // ── issue #804 role emitters (E1: views read nothing raw) ────────────────

  /// The accent SGR prefix — selection re-arming in row chrome needs the
  /// raw prefix, not wrapped text.
  String accentSgr() => sgrPrefix(_current.accent);

  String toolPendingBg(String text) => _render(_current.toolPendingBg, text);

  String customMessageBg(String text) => _render(_current.customMessageBg, text);

  String customMessageText(String text) =>
      _render(_current.customMessageText, text);

  String thinkingText(String text) => _render(_current.thinkingText, text);

  String thinkingOff(String text) => _render(_current.thinkingOff, text);

  String thinkingMinimal(String text) => _render(_current.thinkingMinimal, text);

  String thinkingLow(String text) => _render(_current.thinkingLow, text);

  String thinkingMedium(String text) => _render(_current.thinkingMedium, text);

  String thinkingHigh(String text) => _render(_current.thinkingHigh, text);

  String thinkingXhigh(String text) => _render(_current.thinkingXhigh, text);

  String mdHeading(String text) => _render(_current.mdHeading, text);

  String mdLink(String text) => _render(_current.mdLink, text);

  String mdLinkUrl(String text) => _render(_current.mdLinkUrl, text);

  String mdCode(String text) => _render(_current.mdCode, text);

  String mdCodeBlock(String text) => _render(_current.mdCodeBlock, text);

  String mdCodeBlockBorder(String text) =>
      _render(_current.mdCodeBlockBorder, text);

  String mdQuote(String text) => _render(_current.mdQuote, text);

  String mdQuoteBorder(String text) => _render(_current.mdQuoteBorder, text);

  String mdHr(String text) => _render(_current.mdHr, text);

  String mdListBullet(String text) => _render(_current.mdListBullet, text);

  String link(String text) => _render(_current.link, text);

  String toolDiffAdded(String text) => _render(_current.toolDiffAdded, text);

  String toolDiffRemoved(String text) => _render(_current.toolDiffRemoved, text);

  String toolDiffContext(String text) => _render(_current.toolDiffContext, text);

  String syntaxComment(String text) => _render(_current.syntaxComment, text);

  String syntaxKeyword(String text) => _render(_current.syntaxKeyword, text);

  String syntaxFunction(String text) => _render(_current.syntaxFunction, text);

  String syntaxVariable(String text) => _render(_current.syntaxVariable, text);

  String syntaxString(String text) => _render(_current.syntaxString, text);

  String syntaxNumber(String text) => _render(_current.syntaxNumber, text);

  String syntaxType(String text) => _render(_current.syntaxType, text);

  String syntaxOperator(String text) => _render(_current.syntaxOperator, text);

  String syntaxPunctuation(String text) =>
      _render(_current.syntaxPunctuation, text);

  String bashMode(String text) => _render(_current.bashMode, text);

  String pythonMode(String text) => _render(_current.pythonMode, text);

  String statusLineSep(String text) => _render(_current.statusLineSep, text);

  String statusLineModel(String text) => _render(_current.statusLineModel, text);

  String statusLinePath(String text) => _render(_current.statusLinePath, text);

  String statusLineGitClean(String text) =>
      _render(_current.statusLineGitClean, text);

  String statusLineGitDirty(String text) =>
      _render(_current.statusLineGitDirty, text);

  String statusLineContext(String text) =>
      _render(_current.statusLineContext, text);

  String statusLineSpend(String text) => _render(_current.statusLineSpend, text);

  String statusLineStaged(String text) =>
      _render(_current.statusLineStaged, text);

  String statusLineDirty(String text) => _render(_current.statusLineDirty, text);

  String statusLineUntracked(String text) =>
      _render(_current.statusLineUntracked, text);

  String statusLineOutput(String text) =>
      _render(_current.statusLineOutput, text);

  String statusLineCost(String text) => _render(_current.statusLineCost, text);

  String statusLineSubagents(String text) =>
      _render(_current.statusLineSubagents, text);

  /// Restores the boot default.
  void reset() => switchTo(kDefaultTuiTheme.name);

  Style _p(Style style) => profile == null ? style : style.withProfile(profile);

  /// Renders [text] in the current theme's [role], honoring the profile;
  /// no-op (raw text) when styling is off.
  String _render(Style style, String text) =>
      profile == null ? text : _p(style).render(text);

  String accent(String text) => _render(_current.accent, text);

  String accent2(String text) => _render(_current.accent2, text);

  String accent2Soft(String text) => _render(_current.accent2Soft, text);

  /// First accent without bold (banner title, markdown markers).
  String accentSoft(String text) =>
      _render(Style(foregroundRgb: _current.accent.foregroundRgb), text);

  String dim(String text) => _render(_current.muted, text);

  String warning(String text) => _render(_current.warning, text);

  String error(String text) => _render(_current.error, text);

  String success(String text) => _render(_current.success, text);

  /// Backgrounds the echoed user-message lines.
  String userMessageBg(String text) => _render(_current.userMessageBg, text);

  /// Tool-row label role.
  String toolTitle(String text) => _render(_current.toolTitle, text);

  /// Tool-row detail/output role.
  String toolOutput(String text) => _render(_current.toolOutput, text);

  /// Settled-border role.
  String borderMuted(String text) => _render(_current.borderMuted, text);

  /// User-message text role.
  String userMessageText(String text) =>
      _render(_current.userMessageText, text);

  /// Renders [text] in [style] over [tint]'s background (tinted tool
  /// rows); a [tint] without a background renders [style] alone.
  String tinted(Style style, Style tint, String text) => profile == null
      ? text
      : _render(style.copyWith(backgroundRgb: tint.backgroundRgb), text);

  /// Renders [glyph] in [style] (the tool-row state rail).
  String border(Style style, String glyph) => _render(style, glyph);

  // Tool-card phase tints (#807, issue-#804 emitter rule): the card
  // background tint as a raw SGR prefix ('' when styling is off).
  // [toolPendingBgSgr] rides the highlight tint until S1 lands the
  // `toolPendingBg` role — the swap is one line here.

  /// Settled-success card background.
  String toolSuccessBgSgr() => sgrPrefix(_current.toolSuccessBg);

  /// Settled-failure card background.
  String toolErrorBgSgr() => sgrPrefix(_current.toolErrorBg);

  /// In-flight/pending card background (highlight until toolPendingBg).
  String toolPendingBgSgr() => sgrPrefix(_current.highlight);

  /// Card phase foreground styles (the header/icon roles).
  Style get cardSuccessStyle => _current.success;
  Style get cardErrorStyle => _current.error;
  Style get cardPendingStyle => _current.muted;
  Style get cardRunningStyle => _current.accent;

  /// The raw SGR prefix [style] renders with under the active profile
  /// ('' when styling is off). Derived from a probe render so the prefix
  /// always matches the vendor's own emission order byte for byte.
  String sgrPrefix(Style style) {
    if (profile == null) return '';
    const probe = '\uE000';
    final rendered = _p(style).render(probe);
    return rendered.substring(0, rendered.indexOf(probe));
  }
}

// ── Emitters ──────────────────────────────────────────────────────────────
// Drop-in replacements for the old hardwired palette helpers. Byte-identity
// in the truecolor default: bold+fg / fg / faint exactly as before.

/// Bold first accent (headers, titles, active markers).
String tuiAccent(String s) => FaThemeController.instance.accent(s);

/// Bold second accent (tool-call markers, sub-headers).
String tuiAccent2(String s) => FaThemeController.instance.accent2(s);

/// Second accent without bold (dense spans, scroll indicator).
String tuiAccent2Soft(String s) => FaThemeController.instance.accent2Soft(s);

/// Faint secondary text (rules, hints, separators).
String tuiDim(String s) => FaThemeController.instance.dim(s);

/// Warning foreground (approval cautions, retry notices).
String tuiWarning(String s) => FaThemeController.instance.warning(s);

/// Error foreground (denials, failures).
String tuiError(String s) => FaThemeController.instance.error(s);

/// First accent without bold (banner title, markdown markers).
String tuiAccentSoft(String s) => FaThemeController.instance.accentSoft(s);

/// Success foreground (connection confirmations, ok markers).
String tuiSuccess(String s) => FaThemeController.instance.success(s);

/// The raw SGR prefix (e.g. `\x1b[1m\x1b[38;2;…m`) [style] renders with
/// under the active profile — '' when styling is off. For emitters that
/// paint per-line fragments and close the escape themselves (markdown
/// token styles, the user-message echo background).
String tuiSgr(Style style) => FaThemeController.instance.sgrPrefix(style);

/// Raw SGR prefix of the first accent WITHOUT bold — the markdown marker
/// color (bullets, checkboxes, code spans, list numbers).
String tuiAccentSoftSgr() => tuiSgr(
  Style(foregroundRgb: FaThemeController.instance.current.accent.foregroundRgb),
);

/// Raw SGR prefix of the second accent WITHOUT bold (sub-headers pair it
/// with an explicit bold, dense spans use it alone).
String tuiAccent2SoftSgr() =>
    tuiSgr(FaThemeController.instance.current.accent2Soft);

/// Raw SGR prefix of the current theme's muted role.
String tuiDimSgr() => tuiSgr(FaThemeController.instance.current.muted);

/// Raw SGR prefix of the current theme's user-message background.
String tuiUserMessageBgSgr() =>
    tuiSgr(FaThemeController.instance.current.userMessageBg);

/// Raw SGR prefix of the current theme's user-message text role.
String tuiUserMessageTextSgr() =>
    tuiSgr(FaThemeController.instance.current.userMessageText);

/// One echoed user-message line: the userMessageText role over the
/// userMessageBg band (issue #444 defect 4) — an explicit foreground
/// keeps the band readable in every palette; styling-off degrades to
/// plain text (E2).
String tuiUserMessageLine(String text) {
  if (FaThemeController.instance.profile == null) return text;
  return '${tuiUserMessageBgSgr()}${tuiUserMessageTextSgr()}$text\x1b[0m';
}

/// The `>_Fa` mark (issue #444 defect 3): the prompt glyph `>_` in the
/// first accent, the brand `Fa` in the second — ONE composed definition
/// shared by the banner and the per-message prefix.
String tuiFaMark() {
  if (FaThemeController.instance.profile == null) return '>_Fa ';
  return '${tuiAccent('>_')}${tuiAccent2('Fa')} ';
}

/// Paints a laid-out tool row for its lifecycle [state] (issue #444
/// defect 2): the state rail picks a border role — running rows the
/// accent border ([TuiTheme.focusBorder], pi's `borderAccent`), settled
/// rows [TuiTheme.borderMuted], done/failed rows the success/error tints
/// ([TuiTheme.toolSuccessBg]/[TuiTheme.toolErrorBg]); label and detail render
/// in [TuiTheme.toolTitle]/[TuiTheme.toolOutput]. No profile → a plain rail
/// + row, deterministically (E2).
String tuiToolRow(LaidOutToolRow row, ToolRowState state) {
  final c = FaThemeController.instance;
  if (c.profile == null) return '│ ${row.join()}';
  final softAccent = Style(foregroundRgb: c.current.accent.foregroundRgb);
  final (rail, glyph, tint) = switch (state) {
    ToolRowState.running => (
      c.current.focusBorder,
      c.current.accent2Soft,
      const Style(),
    ),
    ToolRowState.settled => (c.current.borderMuted, softAccent, const Style()),
    ToolRowState.done => (
      c.current.success,
      Style(foregroundRgb: c.current.success.foregroundRgb, isBold: true),
      c.current.toolSuccessBg,
    ),
    ToolRowState.failed => (
      c.current.error,
      c.current.error,
      c.current.toolErrorBg,
    ),
  };
  // gh-671: text painted OVER a theme tint always carries an explicit,
  // floor-checked foreground and drops the dim flag — the terminal
  // default fg is invisible on light tints (the ohmypi-light failed-row
  // screenshot), and SGR 2 halves contrast unpredictably across
  // terminals. Failed rows render [TuiTheme.userMessageText] (the
  // palette's readable-on-painted-surface text, bright in dark themes —
  // the issue #366 "keep failure text bright" intent, now
  // terminal-independent); done rows render the toolOutput foreground
  // without its dim flag. Unpainted running/settled rows keep the
  // classic dim look over the terminal's own background.
  final overTint = state == ToolRowState.done || state == ToolRowState.failed;
  final toolOutputFg = c.current.toolOutput.foregroundRgb;
  final failedFg = c.current.userMessageText.foregroundRgb;
  final painted = row.style(
    glyph: (s) => c.tinted(glyph, tint, s),
    label: (s) => c.tinted(c.current.toolTitle, tint, s),
    dim: (s) {
      if (state == ToolRowState.failed) {
        return failedFg == null
            ? c.tinted(const Style(), tint, s)
            : c.tinted(Style(foregroundRgb: failedFg), tint, s);
      }
      if (overTint && toolOutputFg != null) {
        return c.tinted(Style(foregroundRgb: toolOutputFg), tint, s);
      }
      return c.tinted(c.current.toolOutput, tint, s);
    },
  );
  return '${c.border(rail, '│')} $painted';
}

// ── Swatch/table rendering ────────────────────────────────────────────────

/// One `███` run in [style]'s foreground; plain text when styling is off.
String _swatch(Style style, String label) =>
    FaThemeController.instance.profile == null
    ? label
    : style.withProfile(FaThemeController.instance.profile).render(label);

/// A live-preview swatch row for [theme]: colored blocks sampling the
/// palette's load-bearing roles. Plain blocks when styling is off.
String themeSwatchRow(TuiTheme theme) {
  String block(Style style) => _swatch(style, '███');

  return [
    block(theme.accent),
    block(theme.accent2),
    block(theme.success),
    block(theme.warning),
    block(theme.error),
    block(theme.userMessageBg),
  ].join();
}

/// The `/theme` listing lines: name + swatch + `(current)` marker. User
/// themes follow the built-ins, marked by source.
List<String> themeTableLines({String? current}) {
  final available = FaThemeController.instance.available();
  return [
    for (final entry in available.entries)
      '${entry.key == current ? '›' : ' '} '
          '${entry.key.padRight(13)} '
          '${themeSwatchRow(entry.value)}'
          '${kBuiltInTuiThemes.containsKey(entry.key) ? '' : '  (user)'}',
  ];
}

/// The `/theme` picker rows (gh-671): EVERY theme shows its live swatch
/// preview, and the session-current theme adds a `✓ current` marker in
/// the success role — readable text, never a color-only cue. The old
/// picker REPLACED the current theme's swatch with a dim `(current)`
/// string, so the selection could disappear entirely in low-contrast
/// palettes. Combine with `openPicker(..., initialKey: current)` — the
/// cursor starts on the current row.
List<MenuItem> themePickerItems({String? current}) {
  final controller = FaThemeController.instance;
  return [
    for (final entry in controller.available().entries)
      MenuItem(
        key: entry.key,
        label: entry.key,
        description: entry.key == current
            ? '${themeSwatchRow(entry.value)}  ${controller.success('✓ current')}'
            : themeSwatchRow(entry.value),
      ),
  ];
}

/// WCAG relative luminance of [c] (exported for the accessibility floors).
double themeLuminance(RgbColor c) => _relativeLuminance(c);

/// WCAG contrast ratio between two colors (1:1–21:1).
double themeColorContrast(RgbColor a, RgbColor b) => _contrastRatio(a, b);

/// The terminal background [theme] was designed against: light palettes
/// (a bright userMessageBg) reference a light terminal, dark ones a dark
/// one (gh-671 floors — muted/accent text is judged on its own home
/// terminal, the way [themeContrast] already frames base text).
RgbColor themeReferenceTerminalBg(TuiTheme theme) {
  final bg = theme.userMessageBg.backgroundRgb ?? const RgbColor(0, 0, 0);
  return _relativeLuminance(bg) > 0.5
      ? const RgbColor(0xff, 0xff, 0xff)
      : const RgbColor(0x1e, 0x1e, 0x28);
}

/// WCAG-ish sanity floor for E2: base fg must stay readable against the
/// message background in the same palette (contrast ratio ≥ 2.5).
double themeContrast(TuiTheme theme) {
  final bg = theme.userMessageBg.backgroundRgb ?? const RgbColor(0, 0, 0);
  // Base text inherits the terminal's own foreground (oh-my-pi light.json
  // ships "text": "" too), so the reference fg contrasts with whatever
  // the terminal bg is: dark-on-light palettes, light-on-dark ones.
  final fg =
      theme.base.foregroundRgb ??
      (_relativeLuminance(bg) > 0.5
          ? const RgbColor(0x1a, 0x1a, 0x1a)
          : const RgbColor(204, 204, 204));
  return _contrastRatio(fg, bg);
}

/// The user-message readability floor (issue #444 AC4): contrast of
/// [TuiTheme.userMessageText] against [TuiTheme.userMessageBg]. A theme
/// leaving the text role unset reads against the plain base fg.
double themeUserMessageContrast(TuiTheme theme) {
  final bg = theme.userMessageBg.backgroundRgb ?? const RgbColor(0, 0, 0);
  final fg =
      theme.userMessageText.foregroundRgb ??
      theme.base.foregroundRgb ??
      (_relativeLuminance(bg) > 0.5
          ? const RgbColor(0x1a, 0x1a, 0x1a)
          : const RgbColor(204, 204, 204));
  return _contrastRatio(fg, bg);
}

double _relativeLuminance(RgbColor c) {
  double channel(int v) {
    final s = v / 255;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrastRatio(RgbColor a, RgbColor b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}
