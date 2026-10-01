import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The #1152 path-guard surface in line mode: a message that STARTS with a
/// path is a message (the folder rides verbatim when it exists), a BARE
/// single-token path keeps the load-hint/attach guard, and the guard's
/// fallback never drops clipboard chips. Split out of agent_cli_test.dart
/// to keep both files under the 2800-line gate (CI static guard).
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    Model model = testModel,
    ExecutionEnv? envOverride,
    ApprovalMode approvalMode = ApprovalMode.yolo,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: envOverride ?? env,
        sessionRoot: '/sessions',
        approvalMode: approvalMode,
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  test('unknown slash commands show a filtered command menu', () async {
    final fake = FakeStreamFunction([]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/bogus');
    await waitForIt(
      () => io.out.toString().contains('unknown command: /bogus'),
    );
    io.sendLine('/exit');
    await run;
  });

  test('a message that starts with a nonexistent path is a message, sent '
      'verbatim — never refused (issue #1152 AC1)', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    const message =
        '/var/folders/fa_missing_1152/clip.txt посмотри лог и расскажи';
    io.sendLine(message);
    await waitForIt(() => io.out.toString().contains('ok'));
    expect(
      io.out.toString(),
      isNot(contains('looks like a filesystem path')),
      reason: 'multi-word input is a message, not a bare path',
    );
    expect(io.out.toString(), isNot(contains('unknown command:')));
    expect(
      messageText(fake.contexts.last.messages.last as UserMessage),
      message,
      reason: 'the agent receives the full sentence verbatim',
    );
    io.sendLine('/exit');
    await run;
  });

  test('a message that starts with an EXISTING folder is sent, never refused '
      '(issue #1152 AC2/E3)', () async {
    final dir = await Directory.systemTemp.createTemp('fa_dir_test_1152');
    addTearDown(() => dir.delete(recursive: true));
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    final message = '${dir.path} что внутри этой папки?';
    io.sendLine(message);
    await waitForIt(() => io.out.toString().contains('ok'));
    expect(io.out.toString(), isNot(contains('looks like a filesystem path')));
    // A folder rides verbatim (the @folder semantics): the model sees
    // the path and explores it with its own tools.
    expect(
      messageText(fake.contexts.last.messages.last as UserMessage),
      message,
    );
    io.sendLine('/exit');
    await run;
  });

  test('a bare single-token path that does not exist still shows the load '
      'hint and starts no run (issue #1152 AC3)', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('/var/folders/fa_missing_1152/clip.txt');
    await waitForIt(
      () => io.out.toString().contains('looks like a filesystem path'),
    );
    expect(fake.calls, 0, reason: 'a bare missing path is only a hint');
    io.sendLine('/exit');
    await run;
  });

  test('a bare single-token path that EXISTS attaches and starts the run '
      '(issue #1152 AC4)', () async {
    final dir = await Directory.systemTemp.createTemp('fa_path_test');
    final file = File('${dir.path}/note.md')..writeAsStringSync('hello');
    addTearDown(() => dir.delete(recursive: true));
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine(file.path);
    await waitForIt(
      () => io.out.toString().contains('[file] pasted path attached'),
    );
    await waitForIt(() => io.out.toString().contains('ok'));
    expect(
      messageText(fake.contexts.last.messages.last as UserMessage),
      contains('[attached file:'),
    );
    io.sendLine('/exit');
    await run;
  });

  test('an unknown slash token followed by text is a message, not an '
      '"unknown command" (issue #1152 AC5)', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    const message = '/unknowntoken объясни этот вывод';
    io.sendLine(message);
    await waitForIt(() => io.out.toString().contains('ok'));
    expect(io.out.toString(), isNot(contains('unknown command:')));
    expect(
      messageText(fake.contexts.last.messages.last as UserMessage),
      message,
    );
    io.sendLine('/exit');
    await run;
  });

  test('an unknown slash token with text keeps its clipboard chips '
      '(issue #1152: the guard fallback carries images)', () async {
    const chip = TuiImageAttachment(
      name: 'clipboard-1.png',
      mimeType: 'image/png',
      bytes: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3],
    );
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    const message = '/unknowntoken объясни этот вывод';
    await cli.tuiSubmitForTest(message, [chip]);
    await waitForIt(() => io.out.toString().contains('ok'));
    final blocks =
        (fake.contexts.last.messages.last as UserMessage).content
            as List<ContentBlock>;
    expect(
      blocks.whereType<TextContent>().map((b) => b.text).join(' '),
      contains(message),
    );
    expect(blocks.whereType<ImageContent>(), hasLength(1));
    io.sendLine('/exit');
    await run;
  });

  test('a pasted absolute path that EXISTS is sent as a message with the file '
      'attached, not refused', () async {
    final dir = await Directory.systemTemp.createTemp('fa_path_test');
    final file = File('${dir.path}/clip_note.txt');
    await file.writeAsString('hello from the clip');
    addTearDown(() => dir.delete(recursive: true));

    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();

    io.sendLine('${file.path} summarize this');
    await waitForIt(
      () => io.out.toString().contains('[file] pasted path attached'),
      reason: 'an existing path attaches and starts the run',
    );
    await waitForIt(() => io.out.toString().contains('ok'));
    expect(io.out.toString(), isNot(contains('looks like a filesystem path')));
    io.sendLine('/exit');
    await run;
  });
}
