import 'package:flutter_agent_harness/src/cli/terminal_setup.dart';
import 'package:test/test.dart';

void main() {
  // Env lookup from a literal map (the shape of AgentCliConfig.envVarValue).
  EnvVarLookup lookup(Map<String, String> env) =>
      (name) => env[name];

  group('detectTerminalFamily', () {
    test('tmux wins over the inner terminal markers', () {
      expect(
        detectTerminalFamily(
          lookup({
            'TMUX': '/tmp/tmux-1000/default,123,0',
            'TERM_PROGRAM': 'iTerm.app',
          }),
        ),
        'tmux',
      );
    });

    test('protocol terminals are named directly', () {
      expect(detectTerminalFamily(lookup({'KITTY_WINDOW_ID': '1'})), 'kitty');
      expect(
        detectTerminalFamily(lookup({'GHOSTTY_RESOURCES_DIR': '/x'})),
        'ghostty',
      );
      expect(
        detectTerminalFamily(lookup({'WEZTERM_EXECUTABLE': '/wezterm'})),
        'wezterm',
      );
      expect(
        detectTerminalFamily(lookup({'WT_SESSION': 'abc'})),
        'windows-terminal',
      );
      expect(
        detectTerminalFamily(lookup({'KONSOLE_VERSION': '220403'})),
        'konsole',
      );
      expect(
        detectTerminalFamily(lookup({'XTERM_VERSION': 'XTerm(388)'})),
        'xterm',
      );
      expect(
        detectTerminalFamily(lookup({'ALACRITTY_LOG': '/x'})),
        'alacritty',
      );
      expect(detectTerminalFamily(lookup({'TERM': 'xterm-kitty'})), 'kitty');
      expect(detectTerminalFamily(lookup({'TERM': 'alacritty'})), 'alacritty');
      expect(detectTerminalFamily(lookup({'TERM': 'foot'})), 'foot');
    });

    test('TERM_PROGRAM names macOS and editor terminals', () {
      expect(
        detectTerminalFamily(lookup({'TERM_PROGRAM': 'iTerm.app'})),
        'iterm2',
      );
      expect(
        detectTerminalFamily(lookup({'TERM_PROGRAM': 'Apple_Terminal'})),
        'apple-terminal',
      );
      expect(
        detectTerminalFamily(lookup({'TERM_PROGRAM': 'vscode'})),
        'vscode',
      );
      expect(
        detectTerminalFamily(lookup({'TERM_PROGRAM': 'WarpTerminal'})),
        'warp',
      );
    });

    test('VTE terminals land on vte; nothing matches unknown', () {
      expect(detectTerminalFamily(lookup({'VTE_VERSION': '7603'})), 'vte');
      expect(detectTerminalFamily(lookup({})), 'unknown');
      expect(detectTerminalFamily((name) => null), 'unknown');
    });
  });

  group('terminalSetupLines', () {
    test('the detected family is announced before the other recipes', () {
      final lines = terminalSetupLines(lookup({'WT_SESSION': 'abc'}));
      final body = lines.join('\n');
      expect(body, contains('Windows Terminal'));
      // The windows-terminal recipe appears BEFORE the generic list: the
      // first recipe block is the detected one.
      final detected = lines.indexWhere((l) => l.contains('sendInput'));
      final others = lines.indexWhere((l) => l.startsWith('Other setups:'));
      expect(detected, greaterThanOrEqualTo(0));
      expect(detected, lessThan(others));
    });

    test('tmux recipe names extended-keys', () {
      final body = terminalSetupLines(
        lookup({'TMUX': '/tmp/tmux-1000/default,123,0'}),
      ).join('\n');
      expect(body, contains('extended-keys'));
    });

    test('VTE users get the honest cannot-rebind answer plus fallbacks', () {
      final body = terminalSetupLines(
        lookup({'VTE_VERSION': '7603'}),
      ).join('\n');
      expect(body, contains('Ctrl+O'));
      expect(body, contains('cannot rebind'));
    });

    test('every page carries the universal fallback keys', () {
      final envs = <EnvVarLookup>[
        lookup({'TMUX': '/tmp/tmux-1000/default,123,0'}),
        lookup({'WT_SESSION': 'abc'}),
        lookup({'VTE_VERSION': '7603'}),
        lookup({'TERM_PROGRAM': 'iTerm.app'}),
        lookup({'KITTY_WINDOW_ID': '1'}),
        lookup({}),
        (name) => null,
      ];
      for (final env in envs) {
        final body = terminalSetupLines(env).join('\n');
        expect(body, contains('Ctrl+O'));
        expect(body, contains('Alt+Enter'));
        expect(body, contains('Enter submits'));
      }
    });

    test('unknown terminals still get recipes and the fallback footer', () {
      final body = terminalSetupLines((name) => null).join('\n');
      expect(body, contains('extended-keys'));
      expect(body, contains('sendSequence'));
      expect(body, contains('Ctrl+O inserts a newline'));
    });
  });
}
