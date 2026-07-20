import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Guard: the `--help` reference must stay complete — every flag
/// `parseCliArgs` accepts and every user-facing feature the binary wires
/// must be mentioned. When you add a flag or a config section, add it here
/// AND to `cliHelpText`.
void main() {
  group('cliHelpText', () {
    // Every flag accepted by parseCliArgs (see lib/src/cli/cli_args.dart).
    const flags = [
      '--help',
      '-h',
      '--version',
      '--model',
      '--provider',
      '--base-url',
      '--system-prompt',
      '--system-prompt-file',
      '--vision-model',
      '--vision-base-url',
      '--transcribe-model',
      '--transcribe-base-url',
      '--plugin',
      '--prompt-template-dir',
      '--mode',
      '--cwd',
      '--session-root',
      '--prompt',
      '-p',
    ];
    for (final flag in flags) {
      test('mentions flag $flag', () {
        expect(cliHelpText, contains(flag));
      });
    }

    // Feature keywords: providers, config sections, approval modes, session
    // commands, tools, plugins, and file locations.
    const keywords = [
      // Invocation.
      'interactive REPL',
      'headless',
      'Exit codes: 0 ok',
      // Providers and keys.
      'openai-completions',
      'anthropic',
      'google',
      'OPENROUTER_API_KEY',
      'OPENAI_API_KEY',
      'ANTHROPIC_API_KEY',
      'GOOGLE_API_KEY',
      'VISION_API_KEY',
      'TRANSCRIBE_API_KEY',
      'BRAVE_API_KEY',
      'TAVILY_API_KEY',
      'Ollama',
      'OPENROUTER_API_KEY_2',
      'whisper-1',
      // Model roles.
      'roles:',
      'modelOverrides:',
      'retry:',
      'smol',
      'retriesPerEntry',
      // Prompts.
      'prompts:',
      'cli/mode_code',
      'cli/mode_architect',
      'cli/mode_review',
      'compaction/summary',
      'compaction/summary_system',
      'compaction/summary_update',
      'compaction/turn_prefix',
      '{{cwd}}',
      '/code',
      '/architect',
      '/review',
      // Approvals.
      'always-ask',
      'yolo',
      '/approval',
      '/allow',
      // Sessions and compaction.
      '~/.fah/sessions',
      '/reset',
      '/compact',
      '/stats',
      'checkpoint',
      'rewind',
      'ttsr:',
      '.fah/rules.yaml',
      // Tools.
      'read',
      'write',
      'edit',
      'ls',
      'bash',
      'web_search',
      'web_fetch',
      'lsp',
      'ask',
      'inspect_image',
      'transcribe_audio',
      '.fah/lsp.json',
      // Plugins and templates.
      '.fah/packages.yaml',
      '.fah/prompts',
      // REPL commands.
      '/exit',
      '/model',
      '/mode',
      '/help',
      // Config file.
      '~/.fah/config.yaml',
    ];
    for (final keyword in keywords) {
      test('mentions $keyword', () {
        expect(cliHelpText, contains(keyword));
      });
    }

    test('documents the flag > config > built-in resolution order', () {
      expect(
        cliHelpText,
        contains('--system-prompt[-file] flag > config prompts: override'),
      );
    });

    test('lists the overridable prompt names from the registry', () {
      for (final name in overridablePromptNames.keys) {
        expect(cliHelpText, contains(name), reason: 'missing prompt $name');
      }
    });
  });
}
