import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/slash_menu.dart'
    as slash_menu
    show builtinSlashCommands;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// An immediately-ending stream: every call emits one fixed text turn —
/// for `/handoff` this is the digest LM call's answer.
class _InstantStream {
  _InstantStream(this.text);

  final String text;
  int calls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    calls++;
    final stream = AssistantMessageEventStream();
    stream
      ..push(StartEvent(partial: testAssistant()))
      ..push(
        DoneEvent(
          reason: StopReason.stop,
          message: testAssistant(content: [TextContent(text: text)]),
        ),
      )
      ..end();
    return stream;
  }
}

/// A stream whose calls fail with a provider error — the digest failure rig.
class _FailingStream {
  int calls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    calls++;
    final stream = AssistantMessageEventStream();
    stream
      ..push(StartEvent(partial: testAssistant()))
      ..push(
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'provider down',
          ),
        ),
      )
      ..end();
    return stream;
  }
}

/// The external-editor simulator: a decorator whose `exec` plays the editor
/// — a command naming the handoff digest file rewrites it with [edited]
/// (empty string = the user cleared the file). Keeps the delegate's
/// ranged-read + rename capabilities (session boot probes both through
/// `ForwardingRangedReadFs`/`ForwardingRenamableFs` — a bare ForwardingFs
/// silently downgrades them and the boot's quick name scan dies).
final class EditorSimEnv extends ForwardingFs
    with ForwardingRangedReadFs, ForwardingRenamableFs {
  EditorSimEnv(super.delegate, {required this.edited});

  final String edited;
  final commands = <String>[];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    final marker = RegExp(r"'([^']*handoff-digest[^']*)'").firstMatch(command);
    final path = marker?.group(1);
    if (path != null) {
      // The "editor" rewrites the digest file before the flow reads it back.
      await writeFile(path, edited);
    }
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

AssistantMessage _readCalls(List<String> paths) => AssistantMessage(
  content: [
    for (final (i, path) in paths.indexed)
      ToolCall(id: 'call-r$i', name: 'read', arguments: {'path': path}),
  ],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.toolUse,
  timestamp: DateTime.utc(2026),
);

/// `/handoff` (gh-2102): digest → edit → fresh session seeded with the
/// digest + relevant-file list; the old session stays byte-identical.
void main() {
  const digestAnswer = '## Goal\nfinish the handoff work';

  group('handoffEditorCommand platform quoting (gh-2102 review)', () {
    test('POSIX sh -c: single quotes with the \'\\\'\' escape', () {
      expect(
        handoffEditorCommand('vi', '/work/.fah/a b.md', isWindows: false),
        "vi '/work/.fah/a b.md'",
      );
      expect(
        handoffEditorCommand("vi", "/work/.fah/it's.md", isWindows: false),
        r"vi '/work/.fah/it'\''s.md'",
      );
    });

    test('Windows cmd /c: double quotes — single quotes are LITERAL there '
        'and used to ride into the file name, so the editor could never '
        'open the real digest (gh-2102 review)', () {
      final command = handoffEditorCommand(
        'code --wait',
        r'C:\work\.fah\handoff-digest-1.md',
        isWindows: true,
      );
      expect(command, r'code --wait "C:\work\.fah\handoff-digest-1.md"');
      expect(
        command.contains("'"),
        isFalse,
        reason: 'no single quote may reach the cmd /c argv',
      );
    });
  });

  /// The .jsonl session file paths of the '/work' folder, sorted — via the
  /// repo listing (sessions are grouped under `<root>/<encoded-cwd>/`).
  Future<List<String>> sessionFiles(JsonlSessionRepo repo) async =>
      (await repo.list(cwd: '/work')).map((m) => m.path).toList()..sort();

  Future<JsonlSessionRepo> repoFor(ExecutionEnv env) =>
      Future.value(JsonlSessionRepo(fs: env, sessionsRoot: '/sessions'));

  Future<Session> seedOldSession(
    JsonlSessionRepo repo, {
    required String name,
  }) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    // The name lands FIRST: the boot's quick name scan reads the file head
    // (sessionNameQuick), so a name after the messages would not be seen
    // and the CLI would boot on a brand-new session instead of this one.
    await session.appendSessionName(name);
    await session.appendMessage(UserMessage.text('earlier work'));
    await session.appendMessage(_readCalls(['/src/one.dart', '/src/two.dart']));
    return session;
  }

  AgentCli bootCli(
    ExecutionEnv env,
    FakeCliIO io,
    StreamFunction stream, {
    String? sessionName,
    String? Function(String name)? envVarValue,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        sessionName: sessionName,
        envVarValue: envVarValue,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: stream,
    );
  }

  test(
    '/handoff edits the digest and seeds a fresh session; the old session '
    'stays byte-identical',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = EditorSimEnv(
        MemoryExecutionEnv(cwd: '/work'),
        edited: '$digestAnswer\n(EDITED BY USER)',
      );
      final repo = await repoFor(env);
      await seedOldSession(repo, name: 'old');
      final oldFilePath = (await sessionFiles(repo)).single;
      final beforeBytes = (await env.readTextFile(oldFilePath)).valueOrNull!;

      final io = FakeCliIO();
      final stream = _InstantStream(digestAnswer);
      final cli = bootCli(
        env,
        io,
        stream.call,
        sessionName: 'old',
        envVarValue: (name) => name == 'FA_EDITOR' ? 'true-editor' : null,
      );
      final run = cli.run();
      io.sendLine('/handoff');
      await waitForIt(
        () => io.out.toString().contains('handed off'),
        reason: 'handoff receipt',
      );

      // The editor opened the digest file.
      expect(
        env.commands.where((c) => c.contains('true-editor')),
        hasLength(1),
      );
      // Receipt names the old session as the cross-session link back.
      expect(io.out.toString(), contains("fa --session 'old'"));

      // OLD SESSION BYTE-IDENTICAL (lossless guarantee).
      expect((await env.readTextFile(oldFilePath)).valueOrNull, beforeBytes);

      // The fresh session carries the EDITED digest + the file list.
      final files = await sessionFiles(repo);
      expect(files, hasLength(2));
      final newFilePath = files.singleWhere((name) => name != oldFilePath);
      final newRaw = (await env.readTextFile(newFilePath)).valueOrNull!;
      expect(newRaw, contains('handoff_digest'));
      expect(newRaw, contains('(EDITED BY USER)'));
      expect(newRaw, contains('/src/one.dart'));
      expect(newRaw, contains('/src/two.dart'));

      // The scratch digest file is cleaned up after the flow.
      final scratch =
          ((await env.listDir('/work/.fah')).valueOrNull ?? const <FileInfo>[])
              .map((e) => e.name)
              .where((name) => name.contains('handoff-digest'))
              .toList();
      expect(scratch, isEmpty);

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test(
    '/handoff without an editor keeps the generated digest and says so',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = EditorSimEnv(
        MemoryExecutionEnv(cwd: '/work'),
        edited: 'should never be written',
      );
      final repo = await repoFor(env);
      await seedOldSession(repo, name: 'old');
      final oldFilePath = (await sessionFiles(repo)).single;
      final io = FakeCliIO();
      final cli = bootCli(
        env,
        io,
        _InstantStream(digestAnswer).call,
        sessionName: 'old',
        envVarValue: (_) => null, // no editor configured
      );
      final run = cli.run();
      io.sendLine('/handoff');
      await waitForIt(
        () => io.out.toString().contains('handed off'),
        reason: 'handoff receipt',
      );

      expect(env.commands, isEmpty); // no editor ran
      expect(io.out.toString(), contains('no editor configured'));

      // The fresh session carries the generated (unedited) digest.
      final files = await sessionFiles(repo);
      expect(files, hasLength(2));
      final newRaw = (await env.readTextFile(
        files.singleWhere((name) => name != oldFilePath),
      )).valueOrNull!;
      expect(newRaw, contains('## Goal'));
      expect(newRaw, contains('finish the handoff work'));
      expect(newRaw, isNot(contains('should never be written')));

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test(
    'an emptied digest cancels the handoff — no new session',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = EditorSimEnv(
        MemoryExecutionEnv(cwd: '/work'),
        edited: '   \n', // the user cleared the file
      );
      final repo = await repoFor(env);
      await seedOldSession(repo, name: 'old');
      final oldFilePath = (await sessionFiles(repo)).single;
      final io = FakeCliIO();
      final cli = bootCli(
        env,
        io,
        _InstantStream(digestAnswer).call,
        sessionName: 'old',
        envVarValue: (name) => name == 'FA_EDITOR' ? 'true-editor' : null,
      );
      final run = cli.run();
      io.sendLine('/handoff');
      await waitForIt(
        () => io.out.toString().contains('handoff cancelled'),
        reason: 'cancel note',
      );

      final files = await sessionFiles(repo);
      expect(files, hasLength(1));
      expect(files.single, oldFilePath);

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test(
    'a failed digest keeps the session — no switch, visible error',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = EditorSimEnv(MemoryExecutionEnv(cwd: '/work'), edited: 'x');
      final repo = await repoFor(env);
      await seedOldSession(repo, name: 'old');
      final io = FakeCliIO();
      final stream = _FailingStream();
      final cli = bootCli(
        env,
        io,
        stream.call,
        sessionName: 'old',
        envVarValue: (name) => name == 'FA_EDITOR' ? 'true-editor' : null,
      );
      final run = cli.run();
      io.sendLine('/handoff');
      await waitForIt(
        () => io.out.toString().contains('handoff digest failed'),
        reason: 'digest failure note',
      );

      expect(stream.calls, 1); // the digest call, nothing after it
      expect(await sessionFiles(repo), hasLength(1));

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test(
    '/handoff on an empty session is a no-op with a hint',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = EditorSimEnv(MemoryExecutionEnv(cwd: '/work'), edited: 'x');
      final repo = await repoFor(env);
      final io = FakeCliIO();
      final stream = _InstantStream(digestAnswer);
      final cli = bootCli(env, io, stream.call);
      final run = cli.run();
      io.sendLine('/handoff');
      await waitForIt(
        () => io.out.toString().contains('nothing to hand off'),
        reason: 'empty-session hint',
      );

      expect(stream.calls, 0); // no LM call for an empty session
      // Just the boot session — no handoff target session was created.
      expect(await sessionFiles(repo), hasLength(1));

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test('/help lists /handoff', () {
    // Direct source import: the menu map is CLI-internal (not barrel
    // exported); the pin is on the registration itself.
    expect(slash_menu.builtinSlashCommands['/handoff'], isNotNull);
  });

  test(
    'an aborted digest stays in the session',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = EditorSimEnv(MemoryExecutionEnv(cwd: '/work'), edited: 'x');
      final repo = await repoFor(env);
      await seedOldSession(repo, name: 'old');
      final io = FakeCliIO();
      // Every digest call aborts (provider cancelled mid-summary).
      AssistantMessageEventStream aborting(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        stream
          ..push(StartEvent(partial: testAssistant()))
          ..push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: testAssistant(
                stopReason: StopReason.aborted,
                errorMessage: 'cancelled',
              ),
            ),
          )
          ..end();
        return stream;
      }

      final cli = bootCli(
        env,
        io,
        aborting,
        sessionName: 'old',
        envVarValue: (name) => name == 'FA_EDITOR' ? 'true-editor' : null,
      );
      final run = cli.run();
      io.sendLine('/handoff');
      await waitForIt(
        () => io.out.toString().contains('handoff interrupted'),
        reason: 'abort note',
      );

      expect(await sessionFiles(repo), hasLength(1)); // no switch, no editor
      expect(env.commands, isEmpty);

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test(
    'a failing editor keeps the generated digest',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = EditorSimEnv(MemoryExecutionEnv(cwd: '/work'), edited: 'x');
      // The editor "fails": exec errors and never touches the file.
      final failing = _FailingEditorEnv(env);
      final repo = await repoFor(failing);
      await seedOldSession(repo, name: 'old');
      final oldFilePath = (await sessionFiles(repo)).single;
      final io = FakeCliIO();
      final cli = bootCli(
        failing,
        io,
        _InstantStream(digestAnswer).call,
        sessionName: 'old',
        envVarValue: (name) => name == 'FA_EDITOR' ? 'true-editor' : null,
      );
      final run = cli.run();
      io.sendLine('/handoff');
      await waitForIt(
        () => io.out.toString().contains('handed off'),
        reason: 'handoff receipt',
      );

      expect(io.out.toString(), contains('editor exited'));
      // The seeded digest is the GENERATED one (the failing editor wrote
      // nothing), incl. the file list.
      final files = await sessionFiles(repo);
      expect(files, hasLength(2));
      final newRaw = (await env.readTextFile(
        files.singleWhere((name) => name != oldFilePath),
      )).valueOrNull!;
      expect(newRaw, contains('finish the handoff work'));
      expect(newRaw, contains('/src/one.dart'));

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );

  test(
    'Ctrl-C cancels the digest call (#1085 M3): "handoff interrupted", '
    'no session switch, and the next turn is not insta-aborted '
    '(gh-2102 review)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = EditorSimEnv(MemoryExecutionEnv(cwd: '/work'), edited: 'x');
      final repo = await repoFor(env);
      await seedOldSession(repo, name: 'old');
      final io = FakeCliIO();
      // The digest call hangs until cancelled (the user's Ctrl-C); every
      // later call (the next prompt) completes instantly.
      final hanging = AbortableStreamFunction();
      final followup = _InstantStream('still here');
      AssistantMessageEventStream stream(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        if (!hanging.started) {
          return hanging.call(model, context, cancelToken: cancelToken);
        }
        return followup.call(model, context);
      }

      final cli = bootCli(
        env,
        io,
        stream,
        sessionName: 'old',
        envVarValue: (name) => name == 'FA_EDITOR' ? 'true-editor' : null,
      );
      final run = cli.run();
      io.sendLine('/handoff');
      await waitForIt(() => hanging.started, reason: 'digest call started');
      io.interrupt();
      await waitForIt(
        () => io.out.toString().contains('handoff interrupted'),
        reason: 'interrupt note',
      );

      // No editor ran, no session switch — the handoff stopped mid-flow.
      expect(env.commands, isEmpty);
      expect(await sessionFiles(repo), hasLength(1));
      // The sticky abort belt must NOT ride into the next turn (#1085 M3
      // round-2): the interrupt cancelled the digest call ONLY — the next
      // prompt starts a fresh run and completes it.
      io.sendLine('after the interrupt');
      await waitForIt(
        () => followup.calls >= 1 && !cli.isBusy,
        reason: 'the next turn completes',
      );

      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );
}

/// An editor-sim variant whose `exec` fails for the digest edit — the
/// digest stays unedited (the LM call is not wasted).
final class _FailingEditorEnv extends ForwardingFs
    with ForwardingRangedReadFs, ForwardingRenamableFs {
  _FailingEditorEnv(super.delegate);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    if (command.contains('handoff-digest')) {
      return const Err(
        ExecutionError(ExecutionErrorCode.unknown, 'editor crashed'),
      );
    }
    return delegate.exec(command, options: options);
  }
}
