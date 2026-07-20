import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('parseCliArgs', () {
    test('no args is interactive REPL mode', () {
      final result = parseCliArgs(const []);
      expect(result, isA<CliArgs>());
      final args = result as CliArgs;
      expect(args.isHeadless, isFalse);
      expect(args.prompt, isNull);
      expect(args.positionals, isEmpty);
      expect(args.provider, 'openai-completions');
    });

    test('a single positional is the headless prompt source', () {
      final args = parseCliArgs(const ['summarize the changelog']) as CliArgs;
      expect(args.isHeadless, isTrue);
      expect(args.positionals, ['summarize the changelog']);
      expect(args.prompt, isNull);
    });

    test('multiple positionals are preserved in order (joined later)', () {
      final args = parseCliArgs(const ['fix', 'the', 'typos']) as CliArgs;
      expect(args.positionals, ['fix', 'the', 'typos']);
    });

    test('-p sets the prompt verbatim', () {
      final args = parseCliArgs(const ['-p', 'do the thing']) as CliArgs;
      expect(args.prompt, 'do the thing');
      expect(args.positionals, isEmpty);
      expect(args.isHeadless, isTrue);
    });

    test('--prompt sets the prompt verbatim', () {
      final args = parseCliArgs(const ['--prompt', 'do the thing']) as CliArgs;
      expect(args.prompt, 'do the thing');
      expect(args.isHeadless, isTrue);
    });

    test('-p combined with a positional is an error', () {
      expect(
        () => parseCliArgs(const ['-p', 'text', 'extra']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('cannot combine'),
          ),
        ),
      );
    });

    test('--system-prompt sets the verbatim override', () {
      final args =
          parseCliArgs(const ['--system-prompt', 'You are terse.']) as CliArgs;
      expect(args.systemPrompt, 'You are terse.');
      expect(args.systemPromptFile, isNull);
    });

    test('--system-prompt-file sets the file path', () {
      final args =
          parseCliArgs(const ['--system-prompt-file', '~/prompts/sys.md'])
              as CliArgs;
      expect(args.systemPromptFile, '~/prompts/sys.md');
      expect(args.systemPrompt, isNull);
    });

    test('--system-prompt combined with --system-prompt-file is an error', () {
      expect(
        () => parseCliArgs(const [
          '--system-prompt',
          'x',
          '--system-prompt-file',
          'sys.md',
        ]),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('cannot combine --system-prompt and --system-prompt-file'),
          ),
        ),
      );
    });

    test('unknown flag still fails', () {
      expect(
        () => parseCliArgs(const ['--bogus']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('unknown argument: --bogus'),
          ),
        ),
      );
    });

    test('a dash-prefixed unknown argument fails even next to positionals', () {
      expect(
        () => parseCliArgs(const ['hello', '-x']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('flags and positionals mix freely', () {
      final args =
          parseCliArgs(const [
                '--model',
                'openai/gpt-4o-mini',
                '--cwd',
                '/tmp/work',
                'summarize this',
              ])
              as CliArgs;
      expect(args.model, 'openai/gpt-4o-mini');
      expect(args.cwd, '/tmp/work');
      expect(args.positionals, ['summarize this']);
    });

    test('all long flags parse (moved from bin/fah.dart)', () {
      final args =
          parseCliArgs(const [
                '--model',
                'm',
                '--provider',
                'anthropic',
                '--base-url',
                'https://api.example',
                '--vision-model',
                'gpt-4o',
                '--vision-base-url',
                'https://vision.example',
                '--transcribe-model',
                'whisper-1',
                '--transcribe-base-url',
                'https://transcribe.example',
                '--plugin',
                'inspect_image',
                '--plugin',
                'transcribe_audio',
                '--prompt-template-dir',
                '/a',
                '--prompt-template-dir',
                '/b',
                '--mode',
                'review',
                '--session-root',
                '/sessions',
                '--session',
                'feature-x',
              ])
              as CliArgs;
      expect(args.model, 'm');
      expect(args.provider, 'anthropic');
      expect(args.baseUrl, 'https://api.example');
      expect(args.visionModel, 'gpt-4o');
      expect(args.visionBaseUrl, 'https://vision.example');
      expect(args.transcribeModel, 'whisper-1');
      expect(args.transcribeBaseUrl, 'https://transcribe.example');
      expect(args.plugins, ['inspect_image', 'transcribe_audio']);
      expect(args.promptTemplateDirs, ['/a', '/b']);
      expect(args.mode, 'review');
      expect(args.sessionRoot, '/sessions');
      expect(args.session, 'feature-x');
      expect(args.isHeadless, isFalse);
    });

    test('a missing flag value is an error', () {
      expect(
        () => parseCliArgs(const ['--model']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('--model requires a value'),
          ),
        ),
      );
      expect(
        () => parseCliArgs(const ['-p']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('--prompt requires a value'),
          ),
        ),
      );
    });

    test('unknown provider is an error', () {
      expect(
        () => parseCliArgs(const ['--provider', 'bogus']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('unknown provider: bogus'),
          ),
        ),
      );
    });

    test('--help and -h request usage', () {
      expect(parseCliArgs(const ['--help']), isA<CliArgsHelp>());
      expect(parseCliArgs(const ['-h']), isA<CliArgsHelp>());
    });

    test('--version requests the version', () {
      expect(parseCliArgs(const ['--version']), isA<CliArgsVersion>());
    });
  });
}
