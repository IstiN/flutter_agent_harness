/// The `fah` executable: a terminal coding agent on top of
/// `flutter_agent_harness`.
///
/// Usage:
///
/// ```sh
/// dart run bin/fah.dart [--model <id>] [--provider <kind>] [--base-url <url>]
///                       [--cwd <dir>] [--session-root <dir>]
/// ```
///
/// API keys come from the environment: `OPENROUTER_API_KEY` (fallback
/// `OPENAI_API_KEY`) for the default `openai-completions` provider,
/// `ANTHROPIC_API_KEY` for `anthropic`, `GOOGLE_API_KEY` for `google`.
///
/// This is one of the two places `dart:io` is allowed (the other is
/// `lib/io.dart`); everything it drives is pure Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';

const _version = '0.1.0';

const _usage = '''
fah — flutter_agent_harness CLI agent

Usage: dart run bin/fah.dart [options]

Options:
  --model <id>              Model id (default per provider, see below)
  --provider <kind>         openai-completions | anthropic | google
                            (default: openai-completions, via OpenRouter)
  --base-url <url>          Override the provider API base URL
  --vision-model <id>       Enable inspect_image tool using this vision model
                            (e.g. gpt-4o, openai/gpt-4o)
  --vision-base-url <url>   Override the vision provider base URL
  --cwd <dir>               Working directory (default: current directory)
  --session-root <dir>      Session storage root (default: ~/.fah/sessions)
  --help, -h                Show this help
  --version                 Print the version

Environment:
  OPENROUTER_API_KEY        API key for openai-completions (or OPENAI_API_KEY)
  ANTHROPIC_API_KEY         API key for --provider anthropic
  GOOGLE_API_KEY            API key for --provider google
  VISION_API_KEY            API key for --vision-model (defaults to main key)

Defaults per provider:
  openai-completions    anthropic/claude-sonnet-4 @ https://openrouter.ai/api/v1
  anthropic             claude-sonnet-4-5 @ https://api.anthropic.com
  google                gemini-2.5-pro @ https://generativelanguage.googleapis.com/v1beta
''';

final class _Args {
  _Args({
    this.model,
    this.provider = 'openai-completions',
    this.baseUrl,
    this.visionModel,
    this.visionBaseUrl,
    this.cwd,
    this.sessionRoot,
  });

  final String? model;
  final String provider;
  final String? baseUrl;
  final String? visionModel;
  final String? visionBaseUrl;
  final String? cwd;
  final String? sessionRoot;
}

Never _fail(String message) {
  stderr.writeln('fah: $message');
  stderr.writeln('Run with --help for usage.');
  exit(64);
}

_Args _parseArgs(List<String> args) {
  String? model;
  var provider = 'openai-completions';
  String? baseUrl;
  String? visionModel;
  String? visionBaseUrl;
  String? cwd;
  String? sessionRoot;

  String valueFor(int index, String flag) {
    if (index + 1 >= args.length) _fail('$flag requires a value');
    return args[index + 1];
  }

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--help' || '-h':
        stdout.write(_usage);
        exit(0);
      case '--version':
        stdout.writeln('fah $_version');
        exit(0);
      case '--model':
        model = valueFor(i, '--model');
        i++;
      case '--provider':
        provider = valueFor(i, '--provider');
        i++;
      case '--base-url':
        baseUrl = valueFor(i, '--base-url');
        i++;
      case '--vision-model':
        visionModel = valueFor(i, '--vision-model');
        i++;
      case '--vision-base-url':
        visionBaseUrl = valueFor(i, '--vision-base-url');
        i++;
      case '--cwd':
        cwd = valueFor(i, '--cwd');
        i++;
      case '--session-root':
        sessionRoot = valueFor(i, '--session-root');
        i++;
      default:
        _fail('unknown argument: ${args[i]}');
    }
  }
  if (!const {'openai-completions', 'anthropic', 'google'}.contains(provider)) {
    _fail('unknown provider: $provider');
  }
  return _Args(
    model: model,
    provider: provider,
    baseUrl: baseUrl,
    visionModel: visionModel,
    visionBaseUrl: visionBaseUrl,
    cwd: cwd,
    sessionRoot: sessionRoot,
  );
}

Model _buildModel(_Args args) {
  return switch (args.provider) {
    'anthropic' => Model(
      id: args.model ?? 'claude-sonnet-4-5',
      name: args.model ?? 'claude-sonnet-4-5',
      api: 'anthropic-messages',
      provider: 'anthropic',
      baseUrl: args.baseUrl ?? 'https://api.anthropic.com',
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 8192,
    ),
    'google' => Model(
      id: args.model ?? 'gemini-2.5-pro',
      name: args.model ?? 'gemini-2.5-pro',
      api: 'google-generative-ai',
      provider: 'google',
      baseUrl:
          args.baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta',
      reasoning: true,
      contextWindow: 1000000,
      maxTokens: 8192,
    ),
    _ => Model(
      id: args.model ?? 'anthropic/claude-sonnet-4',
      name: args.model ?? 'anthropic/claude-sonnet-4',
      api: 'openai-completions',
      provider: args.baseUrl == null ? 'openrouter' : 'openai',
      baseUrl: args.baseUrl ?? 'https://openrouter.ai/api/v1',
      reasoning: true,
      contextWindow: 200000,
      maxTokens: 8192,
    ),
  };
}

String _resolveApiKey(String provider, {String? fallback}) {
  final env = Platform.environment;
  final key = switch (provider) {
    'anthropic' => env['ANTHROPIC_API_KEY'],
    'google' => env['GOOGLE_API_KEY'],
    'vision' => env['VISION_API_KEY'] ?? fallback,
    _ => env['OPENROUTER_API_KEY'] ?? env['OPENAI_API_KEY'],
  };
  if (key == null || key.isEmpty) {
    final name = switch (provider) {
      'anthropic' => 'ANTHROPIC_API_KEY',
      'google' => 'GOOGLE_API_KEY',
      'vision' => 'VISION_API_KEY',
      _ => 'OPENROUTER_API_KEY',
    };
    _fail('missing API key: set $name in the environment');
  }
  return key;
}

String _defaultSessionRoot() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    _fail('cannot resolve home directory; pass --session-root');
  }
  return '$home/.fah/sessions';
}

/// [CliIO] bound to the real terminal: stdin lines, stdout writes, and a
/// broadcast interrupt channel fed by the SIGINT handler in `main`.
final class _TerminalCliIO implements CliIO {
  _TerminalCliIO();

  final _interrupts = StreamController<void>.broadcast();

  void fireInterrupt() => _interrupts.add(null);

  @override
  Stream<String> get lines =>
      stdin.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => stdout.write(text);

  @override
  void writeln(String text) => stdout.writeln(text);
}

Future<void> main(List<String> args) async {
  final parsed = _parseArgs(args);
  final model = _buildModel(parsed);
  final apiKey = _resolveApiKey(parsed.provider);
  final cwd = parsed.cwd ?? Directory.current.path;
  final sessionRoot = parsed.sessionRoot ?? _defaultSessionRoot();

  InspectImageConfig? visionConfig;
  if (parsed.visionModel != null) {
    visionConfig = InspectImageConfig(
      modelId: parsed.visionModel!,
      apiKey: _resolveApiKey('vision', fallback: apiKey),
      baseUrl: parsed.visionBaseUrl,
    );
  }

  final io = _TerminalCliIO();
  final cli = AgentCli(
    config: AgentCliConfig(
      model: model,
      apiKey: apiKey,
      providerKind: parsed.provider,
      env: LocalExecutionEnv(cwd: cwd),
      sessionRoot: sessionRoot,
      visionConfig: visionConfig,
    ),
    io: io,
  );

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (cli.isBusy) {
      io.fireInterrupt();
    } else {
      stdout.writeln();
      exit(130);
    }
  });

  try {
    await cli.run();
  } finally {
    await sigintSub.cancel();
  }
}
