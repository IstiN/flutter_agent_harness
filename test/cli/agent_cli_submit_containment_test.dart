/// gh-1787: TUI submit-path crash containment — a throw inside any settings
/// flow reachable from `_handleTuiSubmit` renders as a clean one-line error
/// panel in the transcript, never as a raw Dart stack trace.
///
/// Layers covered:
/// - the containment wrapper (`runContainedSubmit`) and the renderer
///   (`submitErrorPanelLine`) as pure units (UT-1/UT-2, REG-2);
/// - the live boundary: a fake `onModelChanged` host callback that throws
///   is driven through the real TUI `/model-edit` flow; the panel paints
///   and the session stays usable (IT-2, REG-1);
/// - a forced throw between validation and write leaves the config file
///   byte-identical (IT-3, AC4 — validate-first, no partial writes).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'agent_cli_test_support.dart';

/// The incident transcript's stack shape, replayed as DATA (REG-2): the
/// renderer must never re-emit raw-stack-shaped content.
const _incidentStackFixture = '''
Unhandled exception:
StateError: host persist failed
#1      _handleTuiSubmit.<anonymous closure> (package:flutter_agent_harness/src/cli/agent_cli_composer.dart:18)
#2      _handleCommand (package:flutter_agent_harness/src/cli/agent_cli_commands.dart:59)
<asynchronous suspension>
''';

/// The on-disk state the incident started from (the contextWindow pin the
/// host's whole-file persist re-rendered with jsonEncode'd keys).
const _incidentConfig = '''
provider: copilot
model: gemini-4-argon
models:
  overrides:
    "copilot":
      "gemini-4-argon":
        contextWindow: 204800
''';

const _copilotModel = Model(
  id: 'gemini-4-argon',
  api: 'copilot',
  provider: 'copilot',
  baseUrl: 'https://api.githubcopilot.com/',
  contextWindow: 204800,
  maxTokens: 16384,
);

/// Collects rendered frame bytes (dart_tui wraps this into an IOSink).
class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);

  /// The rendered transcript with ANSI control sequences stripped — the
  /// human-readable view the text assertions run against.
  String get plain => text
      .replaceAll(RegExp('\u001B\\][^\u0007]*\u0007'), '')
      .replaceAll(RegExp('\u001B\\[[0-9;?]*[A-Za-z]'), '');
}

/// An [ExecutionEnv] decorator whose `writeFile` can be made to throw —
/// the seam between the flow's validation and the write completing.
final class _ThrowingWriteEnv implements ExecutionEnv {
  _ThrowingWriteEnv(this._delegate);

  final MemoryExecutionEnv _delegate;

  /// When set, every write to [throwOnPath] throws instead of writing.
  String? throwOnPath;

  int get writeAttempts => _writeAttempts;
  int _writeAttempts = 0;

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    _writeAttempts++;
    if (path == throwOnPath) {
      throw StateError('disk full (forced by the test)');
    }
    return _delegate.writeFile(path, content);
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<void, FileError>> writeBinaryFile(String path, Uint8List c) =>
      _delegate.writeBinaryFile(path, c);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _delegate.exec(command, options: options);
}

void main() {
  group('runContainedSubmit (the containment wrapper, UT-1)', () {
    test('a synchronous throw is reported, never rethrown', () async {
      final reported = <Object>[];
      await runContainedSubmit(
        () => throw StateError('sync boom'),
        reported.add,
      );
      expect(reported, hasLength(1));
      expect(reported.single, isA<StateError>());
    });

    test(
      'a Future completing with an error is reported, never rethrown',
      () async {
        final reported = <Object>[];
        await runContainedSubmit(
          () async => throw StateError('async boom'),
          reported.add,
        );
        expect(reported, hasLength(1));
        expect(reported.single, isA<StateError>());
      },
    );

    test('a clean body is reported zero times', () async {
      final reported = <Object>[];
      var ran = false;
      await runContainedSubmit(() async => ran = true, reported.add);
      expect(ran, isTrue);
      expect(reported, isEmpty);
    });
  });

  group('submitErrorPanelLine (the one-line renderer, UT-2/REG-2)', () {
    test('a single-line message rides verbatim, exactly one line', () {
      final line = submitErrorPanelLine(
        const ConfigException(
          'models.overrides.zai.glm-5.3-flash.maxTokens must be at least 1024',
        ),
      );
      expect(line, contains('must be at least 1024'));
      expect(
        line.contains('\n'),
        isFalse,
        reason: 'the panel is ONE line: $line',
      );
      expect(line.contains('asynchronous suspension'), isFalse);
    });

    test(
      'a multi-line parser error collapses to its first meaningful line',
      () {
        final line = submitErrorPanelLine(
          StateError(
            'Error on line 8, column 5: Duplicate mapping key.\n'
            '  ╷\n'
            '8 │     "copilot":\n'
            '  │     ^^^^^^^^^\n'
            '  ╵',
          ),
        );
        expect(
          line,
          contains('Error on line 8, column 5: Duplicate mapping key.'),
        );
        expect(line.contains('\n'), isFalse);
      },
    );

    test('the incident stack shape (replayed as data) renders frame-less', () {
      final line = submitErrorPanelLine(_incidentStackFixture);
      expect(
        line.contains('\n'),
        isFalse,
        reason: 'never re-emitted multi-line: $line',
      );
      expect(line.contains('asynchronous suspension'), isFalse);
      expect(line, isNot(contains('#1')));
      expect(line, isNot(contains('.dart:')));
    });

    test(
      'the zone-dump header never rides the panel — the cause line does',
      () {
        // The fixture's first non-empty line is the bare zone-print
        // header, which names nothing; the CAUSE sits on the next line.
        final line = submitErrorPanelLine(_incidentStackFixture);
        expect(line, 'StateError: host persist failed');
        expect(line, isNot(contains('Unhandled exception')));
      },
    );

    test('a leading header behind blank space still resolves to the cause',
        () {
      final line = submitErrorPanelLine(
        '\n  Unhandled exception:  \nStateError: boot failed\n#1 frame',
      );
      expect(line, 'StateError: boot failed');
    });

    test('a body that merely mentions the header keeps its message', () {
      // Only a LEADING line that IS the literal is the zone header; an
      // error message containing the words is content, not boilerplate.
      final line = submitErrorPanelLine(
        StateError('sub-task failed with: Unhandled exception: rerun it'),
      );
      expect(line, contains('rerun it'));
      expect(line, contains('Unhandled exception'));
    });
  });

  group('the live TUI submit boundary (IT-2/IT-3, REG-1)', () {
    late _FrameSink frames;
    late StreamController<List<int>> keys;
    late MemoryExecutionEnv env;
    late FakeCliIO io;

    setUp(() {
      frames = _FrameSink();
      keys = StreamController<List<int>>();
      env = MemoryExecutionEnv(cwd: '/work');
      io = FakeCliIO();
    });

    tearDown(() => io.close());

    /// Boots the real CLI in TUI mode headlessly over the incident's
    /// config. Returns the booted cli (drive submits; quit with
    /// [quitTui]).
    Future<AgentCli> bootIncidentCli({
      Future<void> Function(Model model)? onModelChanged,
      _ThrowingWriteEnv? throwingEnv,
    }) async {
      await env.writeFile('/home/u/.fah/config.yaml', _incidentConfig);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _copilotModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: throwingEnv ?? env,
          homeDir: '/home/u',
          sessionRoot: '/sessions',
          modelsConfig: ModelsConfig.fromYaml(
            (loadYaml(_incidentConfig) as Map)['models'],
          ),
          onModelChanged: onModelChanged,
          providerKind: 'copilot',
          skillsAccess: SkillsAccess.granted,
          tuiProgramHooks: TuiProgramHooks(
            input: keys.stream,
            output: frames,
            width: 80,
            height: 24,
          ),
        ),
        io: io,
        useTui: true,
        streamFunction: FakeStreamFunction(const []).call,
      );
      final run = cli.run();
      // The test ends via the TUI's own ctrl+c quit; a boot failure must
      // surface as this test's timeout, not a dangling zone error.
      unawaited(run.catchError((Object _) {}));
      await waitForIt(() => frames.text.contains('\x1b[?1049h'));
      return cli;
    }

    /// Boots the CLI and drives the bare `/model-edit` flow to the 65536
    /// max output preset through the real submit boundary. Returns
    /// `(submit, cli)`: the still-running flow's submit future (await it
    /// once the forced failure has been contained) and the booted cli
    /// (drive further submits; quit with [quitTui]).
    Future<(Future<void> submit, AgentCli cli)> openIncidentFlow({
      Future<void> Function(Model model)? onModelChanged,
      _ThrowingWriteEnv? throwingEnv,
    }) async {
      final cli = await bootIncidentCli(
        onModelChanged: onModelChanged,
        throwingEnv: throwingEnv,
      );
      // Bare /model-edit in TUI mode opens the caps flow pre-focused on
      // the ACTIVE model — the incident's exact entry.
      final submit = cli.tuiSubmitForTest('/model-edit', const []);
      await waitForIt(
        () => frames.plain.contains('capabilities — copilot/gemini-4-argon'),
      );
      await cli.tuiWizardPickForTest(
        'wizard:capabilities — copilot/gemini-4-argon',
        'maxTokens',
      );
      await waitForIt(
        () => frames.plain.contains('Enter a number manually'),
        reason: 'the token ladder picker opened',
      );
      return (submit, cli);
    }

    Future<void> quitTui() async {
      keys.add([0x03]); // ctrl+c press 1: arms the double-press window
      keys.add([0x03]); // press 2 within the window quits the TUI
    }

    test(
      'a throwing onModelChanged renders the one-line panel; the write '
      'landed, the session stays usable (IT-2/REG-1)',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        // The fake arms only when the FLOW's apply fires (the boot's
        // endpoint-detection path fires the same callback detached and
        // must not consume the throw), and disarms after one throw — the
        // usability step's follow-up write completes benignly.
        var armed = false;
        final (submit, cli) = await openIncidentFlow(
          onModelChanged: (model) async {
            if (armed) {
              armed = false;
              throw StateError('host persist failed');
            }
          },
        );
        armed = true;
        await cli.tuiWizardPickForTest('wizard:maxTokens in tokens', '65536');
        // The boundary contains the throw: the submit future completes.
        await submit;

        // AC2: the clean one-line panel carries the exception message.
        await waitForIt(
          () => frames.plain.contains('Bad state: host persist failed'),
          reason: 'the error panel painted',
        );
        // AC3/REG-1: the serialized transcript never shows a raw stack.
        expect(
          frames.plain,
          isNot(contains('asynchronous suspension')),
          reason: 'a contained flow error must never paint stack frames',
        );
        // E3: the write itself landed before the apply failed — the next
        // session boots with the new value (no half-state in the file).
        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        final doc = loadYaml(written!) as YamlMap;
        final caps =
            ((doc['models'] as YamlMap)['overrides'] as YamlMap)['copilot']
                as YamlMap;
        expect((caps['gemini-4-argon'] as YamlMap)['maxTokens'], 65536);

        // AC2 (usability): the loop accepts a fresh submit and completes
        // it — the arg form of /model-edit writes with the fake benign.
        final second = cli.tuiSubmitForTest(
          '/model-edit maxTokens 4096',
          const [],
        );
        await second;
        await waitForIt(
          () => frames.plain.contains('model max tokens set to 4096'),
        );
        expect(cli.isBusy, isFalse);

        await quitTui();
      },
    );

    test(
      'a forced throw between validation and write leaves the config '
      'byte-identical (IT-3, AC4)',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        final throwingEnv = _ThrowingWriteEnv(env)
          ..throwOnPath = '/home/u/.fah/config.yaml';
        final (submit, cli) = await openIncidentFlow(throwingEnv: throwingEnv);
        await cli.tuiWizardPickForTest('wizard:maxTokens in tokens', '65536');
        await submit;

        // The clean panel names the forced failure — no raw stack.
        await waitForIt(
          () => frames.plain.contains('disk full (forced by the test)'),
          reason: 'the error panel painted',
        );
        expect(frames.plain, isNot(contains('asynchronous suspension')));

        // AC4: validate-first, no partial writes — the file is EXACTLY
        // the pre-flow state.
        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, _incidentConfig);
        expect(throwingEnv.writeAttempts, greaterThanOrEqualTo(1));

        await quitTui();
      },
    );
  });
}
