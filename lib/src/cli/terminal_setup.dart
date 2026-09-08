/// `/terminal-setup`: per-terminal guidance for Shift+Enter newline support
/// (issue #36).
///
/// Shift+Enter reaches the CLI only when the terminal sends it distinctly.
/// fa enables every in-band protocol at startup — the kitty keyboard
/// protocol and xterm `modifyOtherKeys` (both decoded as a `shift+enter`
/// keystroke), the legacy ESC+CR wire (decoded as `alt+enter`) — and on
/// macOS polls the Shift modifier directly for bare-CR terminals. Terminals
/// that do none of those (VTE/gnome-terminal, tmux without extended keys,
/// unconfigured VS Code / Windows Terminal) fold Shift+Enter into Enter, so
/// it submits. This page tells the user how to fix their terminal, and
/// names the fallback keys that work everywhere today: Ctrl+O inserts a
/// newline in any terminal (a plain control byte), Alt+Enter wherever the
/// terminal sends ESC+CR.
///
/// Pure Dart: the terminal family is detected through an injected env-var
/// lookup (`AgentCliConfig.envVarValue`), never `dart:io`.
library;

/// Signature of the host env lookup (`AgentCliConfig.envVarValue`).
typedef EnvVarLookup = String? Function(String name);

/// Known terminal families with distinct guidance ids.
const terminalSetupFamilies = <String>{
  'kitty',
  'ghostty',
  'foot',
  'wezterm',
  'alacritty',
  'konsole',
  'xterm',
  'iterm2',
  'apple-terminal',
  'warp',
  'vscode',
  'windows-terminal',
  'tmux',
  'vte',
  'unknown',
};

/// Env-var markers checked in order; the first set variable names the
/// family. tmux comes first: it masks the inner terminal's own markers.
const _envFamilyMarkers = <String, List<String>>{
  'tmux': ['TMUX'],
  'kitty': ['KITTY_WINDOW_ID', 'KITTY_PID'],
  'ghostty': ['GHOSTTY_RESOURCES_DIR'],
  'wezterm': ['WEZTERM_EXECUTABLE'],
  'windows-terminal': ['WT_SESSION'],
  'konsole': ['KONSOLE_VERSION'],
  'vte': ['VTE_VERSION'],
  'xterm': ['XTERM_VERSION'],
  'alacritty': ['ALACRITTY_LOG'],
};

/// `TERM_PROGRAM` value → family id.
const _termProgramFamilies = <String, String>{
  'iTerm.app': 'iterm2',
  'Apple_Terminal': 'apple-terminal',
  'WarpTerminal': 'warp',
  'vscode': 'vscode',
  'WezTerm': 'wezterm',
  'ghostty': 'ghostty',
};

/// `TERM` prefix → family id (WSL/Linux terminfo names).
const _termPrefixFamilies = <String, String>{
  'xterm-kitty': 'kitty',
  'xterm-ghostty': 'ghostty',
  'alacritty': 'alacritty',
  'foot': 'foot',
};

/// Detects the terminal family from host env vars (an empty lookup — tests,
/// web — lands on `unknown`).
String detectTerminalFamily(EnvVarLookup env) {
  for (final entry in _envFamilyMarkers.entries) {
    for (final name in entry.value) {
      final value = env(name);
      if (value != null && value.isNotEmpty) return entry.key;
    }
  }
  final program = env('TERM_PROGRAM');
  if (program != null && program.isNotEmpty) {
    final family = _termProgramFamilies[program];
    if (family != null) return family;
  }
  final term = env('TERM') ?? '';
  for (final entry in _termPrefixFamilies.entries) {
    if (term.startsWith(entry.key)) return entry.value;
  }
  return 'unknown';
}

/// The `/terminal-setup` page: detected family first, then the other
/// recipes, then the always-true fallback keys.
List<String> terminalSetupLines(EnvVarLookup env) {
  final family = detectTerminalFamily(env);
  final lines = <String>[
    'Shift+Enter needs a terminal that sends it distinctly. fa enables the',
    'kitty protocol, xterm modifyOtherKeys, and reads the Shift key on',
    'macOS at startup — many terminals just work:',
    '',
  ];
  final detected = _familyRecipe(family);
  if (detected != null) {
    lines.addAll(detected);
    lines.add('');
  }
  lines.addAll([
    'Other setups:',
    ...[
      for (final other in terminalSetupFamilies)
        if (other != family && other != 'unknown')
          ..._familyRecipe(other) ?? const <String>[],
    ],
    '',
    'In EVERY terminal, Ctrl+O inserts a newline in the composer right now',
    '(Alt+Enter works wherever the terminal sends ESC+CR). Enter submits.',
  ]);
  return lines;
}

/// Display names for the kitty-protocol families (recipe headline).
const _kittyProtocolFamilyNames = <String, String>{
  'kitty': 'kitty',
  'ghostty': 'Ghostty',
  'foot': 'foot',
  'wezterm': 'WezTerm',
  'alacritty': 'Alacritty',
  'konsole': 'Konsole',
};

/// Recipe bodies for families outside the kitty-protocol group; `unknown`
/// is absent (its users read the full list + the fallback footer).
const _familyRecipeBodies = <String, List<String>>{
  'xterm': [
    'Your terminal (xterm ≥374) honors modifyOtherKeys, which fa enables',
    'at startup: Shift+Enter already inserts a newline.',
  ],
  'iterm2': [
    'macOS: fa reads the Shift key state directly (Core Graphics), so',
    'Shift+Enter already inserts a newline in iTerm2.',
  ],
  'apple-terminal': [
    'macOS: fa reads the Shift key state directly (Core Graphics), so',
    'Shift+Enter already inserts a newline in Terminal.app.',
  ],
  'warp': [
    'Warp sends Shift+Enter as the legacy ESC+CR wire, which fa decodes:',
    'it already inserts a newline.',
  ],
  'tmux': [
    'tmux: turn on extended keys in ~/.tmux.conf so Shift+Enter is sent',
    '  set -g extended-keys on',
    'then reload (tmux source-file ~/.tmux.conf) or restart tmux.',
  ],
  'vscode': [
    'VS Code: add a keybinding (Preferences: Open Keyboard Shortcuts (JSON)):',
    '  { "key": "shift+enter", "command":',
    '    "workbench.action.terminal.sendSequence",',
    '    "args": { "text": "\\u001b\\r" }, "when": "terminalFocus" }',
  ],
  'windows-terminal': [
    'Windows Terminal: add a keybinding in Settings → Actions (settings.json):',
    '  { "command": { "action": "sendInput", "input": "\\u001b\\r" },',
    '    "keys": "shift+enter" }',
  ],
  'vte': [
    'Your terminal (gnome-terminal / other VTE-based) folds Shift+Enter',
    'into Enter and cannot rebind it. Use Ctrl+O for a new line, or run',
    'fa in a kitty-protocol terminal (kitty, Ghostty, foot, WezTerm,',
    'Alacritty, Konsole) where Shift+Enter works out of the box.',
  ],
};

/// The guidance block for one family.
List<String>? _familyRecipe(String family) {
  final kittyName = _kittyProtocolFamilyNames[family];
  if (kittyName != null) {
    return [
      'Your terminal ($kittyName) supports the kitty keyboard protocol:',
      'Shift+Enter already inserts a newline — nothing to set up.',
    ];
  }
  return _familyRecipeBodies[family];
}
