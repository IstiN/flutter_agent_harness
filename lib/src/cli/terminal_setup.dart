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

/// Detects the terminal family from host env vars (an empty lookup — tests,
/// web — lands on `unknown`). tmux is checked first: it masks the inner
/// terminal's own markers.
String detectTerminalFamily(EnvVarLookup env) {
  String? tryEnv(List<String> names) {
    for (final name in names) {
      final value = env(name);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  if (tryEnv(['TMUX']) != null) return 'tmux';
  if (tryEnv(['KITTY_WINDOW_ID', 'KITTY_PID']) != null) return 'kitty';
  if (tryEnv(['GHOSTTY_RESOURCES_DIR']) != null) return 'ghostty';
  if (tryEnv(['WEZTERM_EXECUTABLE']) != null) return 'wezterm';
  if (tryEnv(['WT_SESSION']) != null) return 'windows-terminal';
  if (tryEnv(['KONSOLE_VERSION']) != null) return 'konsole';
  if (tryEnv(['VTE_VERSION']) != null) return 'vte';
  if (tryEnv(['XTERM_VERSION']) != null) return 'xterm';
  if (tryEnv(['ALACRITTY_LOG']) != null) return 'alacritty';
  if (tryEnv(['TERM_PROGRAM']) case final program?) {
    switch (program) {
      case 'iTerm.app':
        return 'iterm2';
      case 'Apple_Terminal':
        return 'apple-terminal';
      case 'WarpTerminal':
        return 'warp';
      case 'vscode':
        return 'vscode';
      case 'WezTerm':
        return 'wezterm';
      case 'ghostty':
        return 'ghostty';
    }
  }
  final term = tryEnv(['TERM']) ?? '';
  if (term.startsWith('xterm-kitty') || term.startsWith('xterm-ghostty')) {
    return term.startsWith('xterm-kitty') ? 'kitty' : 'ghostty';
  }
  if (term.startsWith('alacritty')) return 'alacritty';
  if (term.startsWith('foot')) return 'foot';
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

/// The guidance block for one family; `unknown` carries no block of its own
/// (its users read the full list + the fallback footer).
List<String>? _familyRecipe(String family) {
  switch (family) {
    case 'kitty':
    case 'ghostty':
    case 'foot':
    case 'wezterm':
    case 'alacritty':
    case 'konsole':
      return [
        'Your terminal ($family) supports the kitty keyboard protocol:',
        'Shift+Enter already inserts a newline — nothing to set up.',
      ];
    case 'xterm':
      return [
        'Your terminal (xterm ≥374) honors modifyOtherKeys, which fa enables',
        'at startup: Shift+Enter already inserts a newline.',
      ];
    case 'iterm2':
    case 'apple-terminal':
      return [
        'macOS: fa reads the Shift key state directly (Core Graphics), so',
        'Shift+Enter already inserts a newline in $family.',
      ];
    case 'warp':
      return [
        'Warp sends Shift+Enter as the legacy ESC+CR wire, which fa decodes:',
        'it already inserts a newline.',
      ];
    case 'tmux':
      return [
        'tmux: turn on extended keys in ~/.tmux.conf so Shift+Enter is sent',
        '  set -g extended-keys on',
        'then reload (tmux source-file ~/.tmux.conf) or restart tmux.',
      ];
    case 'vscode':
      return [
        'VS Code: add a keybinding (Preferences: Open Keyboard Shortcuts (JSON)):',
        '  { "key": "shift+enter", "command":',
        '    "workbench.action.terminal.sendSequence",',
        '    "args": { "text": "\\u001b\\r" }, "when": "terminalFocus" }',
      ];
    case 'windows-terminal':
      return [
        'Windows Terminal: add a keybinding in Settings → Actions (settings.json):',
        '  { "command": { "action": "sendInput", "input": "\\u001b\\r" },',
        '    "keys": "shift+enter" }',
      ];
    case 'vte':
      return [
        'Your terminal (gnome-terminal / other VTE-based) folds Shift+Enter',
        'into Enter and cannot rebind it. Use Ctrl+O for a new line, or run',
        'fa in a kitty-protocol terminal (kitty, Ghostty, foot, WezTerm,',
        'Alacritty, Konsole) where Shift+Enter works out of the box.',
      ];
    default:
      return null;
  }
}
