// Issue #678 — L3 loop/CLI + L4 e2e tests for automatic tool-result
// spilling (TDD RED phase).
//
// L3: the NEXT request's context and the session JSONL both carry the
// bounded symmetric preview — never the raw body (byte-level); `read`
// round-trips the spill path back to the full body; a dangling spill
// path degrades to a named error result with the CLI alive; token
// meters count the PREVIEW while the omitted marker stays truthful;
// the session record renders the stored preview text.
// L4: a scripted marathon of oversized outputs keeps every captured
// window slim with zero mid-turn drops, and `enabled: false` /
// `threshold: 0` / absent `spills:` configs stay byte-identical legacy.
//
// RED phase: the spill skeleton (lib/src/spill/spill.dart) throws
// UnimplementedError. Every test that attaches an ACTIVE spills config
// fails in the AgentCli constructor (attachSpillHooks) until the GREEN
// step lands. The pure-legacy parity test attaches no hook and may
// already pass.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// An oversized single-line body: past every inline bound, under the
/// bash tool's own truncation caps (50KB / 2000 lines) so the hook sees
/// the whole thing.
final _body = 'x' * 20000;

/// Small active config: threshold crossed, preview bounds tiny relative
/// to [_body] so "preview, not body" assertions have huge margins.
const _spills = SpillsConfig(threshold: 1000, headChars: 200, tailChars: 200);

/// Matches the `[... <N> chars omitted ...]` marker pinned by the spill
/// doc comment (AC10: the marker carries the TRUE omitted size). Only
/// the prefix + digits are matched: the digit capture is all the
/// assertions consume, and the pattern avoids the trailing escaped
/// bracket.
final _omittedMarker = RegExp(r'\[\.\.\. (\d+) chars omitted');

void main() {
  test('L3: the next request carries the preview, never the raw body '
      '(byte-level)', () async {
    final turns = [
      toolTurn([_bashCall('c1', 'cat big.log')]),
      textTurn('done'),
    ];
    final rig = await _rig(turns: turns, spills: _spills, shellStdout: _body);
    rig.io.sendLine('go');
    await _settle(rig, 2, 'the tool turn runs and the loop calls back');
    await _exit(rig);

    // Context #2 is the first request built AFTER the oversized tool
    // result existed: it must hold the preview, never the body.
    final text = _toolResultText(rig.fake.contexts.last);
    expect(text, contains('[spill file: '));
    expect(text, matches(_omittedMarker));
    expect(
      text,
      isNot(contains(_body)),
      reason: 'the 20000-char body must never ride the wire',
    );
  });

  test('L3: the session JSONL carries the preview, not the body '
      '(byte-level record)', () async {
    final turns = [
      toolTurn([_bashCall('c1', 'cat big.log')]),
      textTurn('done'),
    ];
    final rig = await _rig(turns: turns, spills: _spills, shellStdout: _body);
    rig.io.sendLine('go');
    await _settle(rig, 2, 'the tool turn runs');
    await _exit(rig);

    final raw = await _sessionJsonl(rig);
    final toolLine = raw
        .split('\n')
        .firstWhere((line) => line.contains('"toolResult"'));
    expect(toolLine, contains('[spill file: '));
    expect(toolLine, matches(_omittedMarker));
    expect(
      raw,
      isNot(contains(_body)),
      reason: 'the session record must store the preview, not the body',
    );
  });

  test('L3: reading the spill path round-trips the full body', () async {
    final turns = [
      toolTurn([_bashCall('c1', 'cat big.log')]),
      textTurn('done'),
    ];
    final rig = await _rig(turns: turns, spills: _spills, shellStdout: _body);
    rig.io.sendLine('go');
    await _settle(rig, 2, 'the spill-producing turn settles');

    // The hook wrote the full redacted body under the session's spill
    // dir; that exact content is what a read round-trip must return.
    final spillPath = await _spillPath(rig, 1);
    final expected = await _readText(rig.env, spillPath);
    expect(expected, _body);

    // The model asks for the details: turn order is LIFO on the fake's
    // list, so insert the read turn plus its closing answer up front.
    turns
      ..insert(
        0,
        toolTurn([
          ToolCall(id: 'c2', name: 'read', arguments: {'path': spillPath}),
        ]),
      )
      ..insert(1, textTurn('full body quoted'));
    rig.io.sendLine('show me');
    await _settle(rig, 4, 'the read round-trip settles');

    final result = _lastToolResult(rig.fake.contexts.last);
    expect(result, isNotNull);
    expect(result!.isError, isFalse);
    // The round-trip answers with the FULL body — a spill-path read is
    // never re-bounded (reading the details is the whole point).
    expect(_textOf(result), contains(expected));
    await _exit(rig);
  });

  test(
    'L3: a dangling spill path degrades to a named error, CLI alive',
    () async {
      final turns = [
        toolTurn([_bashCall('c1', 'cat big.log')]),
        textTurn('done'),
      ];
      final rig = await _rig(turns: turns, spills: _spills, shellStdout: _body);
      rig.io.sendLine('go');
      await _settle(rig, 2, 'the spill-producing turn settles');

      // AC9: the file vanished (deleted / branch from another machine).
      final spillPath = await _spillPath(rig, 1);
      await rig.env.remove(spillPath);

      turns
        ..insert(
          0,
          toolTurn([
            ToolCall(id: 'c2', name: 'read', arguments: {'path': spillPath}),
          ]),
        )
        ..insert(1, textTurn('recovered'));
      rig.io.sendLine('show me');
      await _settle(rig, 4, 'the dangling read settles');

      final result = _lastToolResult(rig.fake.contexts.last);
      expect(result, isNotNull);
      expect(result!.isError, isTrue, reason: 'a missing spill is an ERROR');
      final text = _textOf(result);
      expect(
        text,
        contains('.fah/spills'),
        reason: 'the error names the spill path',
      );
      expect(
        text.contains('No such file') || text.contains('notFound'),
        isTrue,
        reason: 'the error names the not-found condition',
      );

      // The CLI is still alive: the next prompt lands its answer.
      turns
        ..insert(0, textTurn('alive and well'))
        ..insert(1, textTurn('ignored'));
      rig.io.sendLine('ping');
      await _settle(rig, 5, 'the follow-up prompt settles');
      expect(rig.io.out.toString(), contains('alive and well'));
      expect(
        rig.io.out.toString(),
        isNot(contains('Null check')),
        reason: 'no crash',
      );
      await _exit(rig);
    },
  );

  test('L3: meters count the preview and the omitted marker is truthful '
      '(AC10)', () async {
    final turns = [
      toolTurn([_bashCall('c1', 'cat big.log')]),
      textTurn('done'),
    ];
    final rig = await _rig(turns: turns, spills: _spills, shellStdout: _body);
    rig.io.sendLine('go');
    await _settle(rig, 2, 'the spill-producing turn settles');
    await _exit(rig);

    final spilled = _lastToolResult(rig.fake.contexts.last)!;
    final hypotheticalBody = ToolResultMessage(
      toolCallId: spilled.toolCallId,
      toolName: spilled.toolName,
      content: [TextContent(text: _body)],
      isError: false,
      timestamp: DateTime.utc(2026),
    );
    // The preview must dominate the accounting: far below 25% of what
    // the body would have cost.
    final previewTokens = estimateTokens(spilled);
    final bodyTokens = estimateTokens(hypotheticalBody);
    expect(previewTokens, lessThan(bodyTokens ~/ 4));

    // And the preview does not lie about scale: the omitted marker
    // carries the true omitted size (body minus the head+tail bounds).
    final match = _omittedMarker.firstMatch(_textOf(spilled));
    expect(match, isNotNull);
    final omitted = int.parse(match!.group(1)!);
    expect(omitted, _body.length - 200 - 200);
  });

  test('L3: the session record renders the stored preview text', () async {
    final turns = [
      toolTurn([_bashCall('c1', 'cat big.log')]),
      textTurn('done'),
    ];
    final rig = await _rig(turns: turns, spills: _spills, shellStdout: _body);
    rig.io.sendLine('go');
    await _settle(rig, 2, 'the spill-producing turn settles');
    await _exit(rig);

    // What the trajectory renders IS the stored record: the tool-result
    // record must carry the full preview shape (path line, omitted
    // marker, read hint).
    final repo = _repo(rig.env);
    final meta = (await repo.list(cwd: '/work')).single;
    final session = await repo.open(meta);
    final record = (await session.getEntries())
        .whereType<MessageRecord>()
        .map((r) => r.message)
        .whereType<ToolResultMessage>()
        .last;
    final text = _textOf(record);
    expect(text, contains('[spill file: '));
    expect(text, matches(_omittedMarker));
    expect(text, contains(spillReadHint));
    expect(text, isNot(contains(_body)));
  });

  test('L4: a marathon of oversized outputs keeps every window slim with '
      'zero mid-turn drops', () async {
    final turns = [
      toolTurn([_bashCall('c1', 'cat a.log')]),
      textTurn('mid 1'),
      toolTurn([_bashCall('c2', 'cat b.log')]),
      textTurn('mid 2'),
      toolTurn([_bashCall('c3', 'cat c.log')]),
      textTurn('done'),
    ];
    final rig = await _rig(turns: turns, spills: _spills, shellStdout: _body);
    rig.io.sendLine('go');
    await _settle(rig, 2, 'first oversized turn settles');
    rig.io.sendLine('go');
    await _settle(rig, 4, 'second oversized turn settles');
    rig.io.sendLine('go');
    await _settle(rig, 6, 'third oversized turn settles');
    await _exit(rig);

    // Every captured window stayed slim: no raw body anywhere.
    final bodiesChars = 3 * _body.length;
    for (final captured in rig.fake.contexts) {
      expect(_toolResultText(captured), isNot(contains(_body)));
    }
    // The final context's tool results are bounded previews: under 10%
    // of the 60000 body chars the legacy run would have hauled.
    final toolText = _toolResultText(rig.fake.contexts.last);
    expect(toolText.length, lessThan(bodiesChars ~/ 10));

    // ZERO mid-turn drops (#673 cluster): the fake served every scripted
    // turn and the loop surfaced no error lines.
    expect(rig.fake.calls, greaterThanOrEqualTo(6));
    expect(rig.io.out.toString(), isNot(contains('error: ')));
  });

  test('L4/AC1: enabled:false, threshold:0 and absent spills configs are '
      'byte-identical legacy (ids/timestamps normalized)', () async {
    final disabled = await _legacySessionJsonl(
      const SpillsConfig(enabled: false, threshold: 0),
    );
    final absent = await _legacySessionJsonl(null);
    final zeroThreshold = await _legacySessionJsonl(
      const SpillsConfig(threshold: 0),
    );

    // Sanity: legacy keeps the oversized body inline in all three runs.
    expect(disabled, contains(_body));
    // Threshold 0 = disabled = hook never attached = legacy, byte for
    // byte (only the random record ids and timestamps are normalized).
    expect(disabled, absent);
    expect(disabled, zeroThreshold);
  });
}

ToolCall _bashCall(String id, String command) =>
    ToolCall(id: id, name: 'bash', arguments: {'command': command});

/// One wired CLI run: in-memory env + FakeShell + scripted LLM, built
/// exactly like the #673 fixture (openai-completions, classic
/// compaction, memory maintenance suppressed).
class _Rig {
  _Rig(this.env, this.io, this.fake, this.cli, this.run);

  final MemoryExecutionEnv env;
  final FakeCliIO io;
  final FakeStreamFunction fake;
  final AgentCli cli;
  final Future<void> run;
}

Future<_Rig> _rig({
  required List<List<AssistantMessageEvent>> turns,
  SpillsConfig? spills,
  String shellStdout = '',
}) async {
  final env = MemoryExecutionEnv(
    cwd: '/work',
    shell: FakeShell(stdout: shellStdout),
  );
  // Suppress session-start memory maintenance so the scripted turns feed
  // only the turn under test (same pattern as agent_cli_test).
  await env.writeFile('/work/.fah/memory/.last_maintenance', '');
  final io = FakeCliIO();
  final fake = FakeStreamFunction(turns);
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
      spills: spills,
    ),
    io: io,
    streamFunction: fake.call,
  );
  final run = cli.run();
  return _Rig(env, io, fake, cli, run);
}

String _textOf(ToolResultMessage message) => [
  for (final block in message.content)
    if (block is TextContent) block.text,
].join('\n');

String _toolResultText(Context context) => [
  for (final message in context.messages)
    if (message is ToolResultMessage) _textOf(message),
].join('\n');

ToolResultMessage? _lastToolResult(Context context) {
  for (final message in context.messages.reversed) {
    if (message is ToolResultMessage) return message;
  }
  return null;
}

JsonlSessionRepo _repo(MemoryExecutionEnv env) =>
    JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');

Future<String> _readText(MemoryExecutionEnv env, String path) async {
  final result = await env.readTextFile(path);
  if (result.isErr) fail('reading $path failed: ${result.errorOrNull}');
  return result.valueOrNull!;
}

Future<String> _sessionJsonl(_Rig rig) async {
  final meta = (await _repo(rig.env).list(cwd: '/work')).single;
  return _readText(rig.env, meta.path);
}

/// The spill dir lives under the env cwd: `/work/.fah/spills/<sessionId>/`
/// `<n>.txt`, with the session id resolved from the session file name.
Future<String> _spillPath(_Rig rig, int n) async {
  final sessionId = (await _repo(rig.env).list(cwd: '/work')).first.id;
  return '/work/.fah/spills/$sessionId/$n.txt';
}

Future<void> _settle(_Rig rig, int minCalls, String reason) => waitForIt(
  () => rig.fake.calls >= minCalls && !rig.cli.isBusy,
  reason: reason,
);

Future<void> _exit(_Rig rig) async {
  rig.io.sendLine('/exit');
  await rig.run;
  await rig.io.close();
}

/// Runs the shared scripted scenario once under [spills] (null = no
/// config section at all) and returns the session JSONL with the
/// run-varying ids and timestamps normalized away.
Future<String> _legacySessionJsonl(SpillsConfig? spills) async {
  final turns = [
    toolTurn([_bashCall('c1', 'cat big.log')]),
    textTurn('done'),
  ];
  final rig = await _rig(turns: turns, spills: spills, shellStdout: _body);
  rig.io.sendLine('go');
  await _settle(rig, 2, 'the legacy run settles');
  await _exit(rig);
  return _normalize(await _sessionJsonl(rig));
}

String _normalize(String jsonl) => jsonl
    // Bare uuid-shaped tokens anywhere: session ids in the header, the
    // agent inbox address the system prompt embeds.
    .replaceAllMapped(
      RegExp(
        r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      ),
      (_) => 'UUID',
    )
    .replaceAllMapped(RegExp(r'"timestamp":"[^"]*"'), (_) => '"timestamp":"T"')
    .replaceAllMapped(RegExp(r'"timestamp":\d+'), (_) => '"timestamp":0')
    // Content hashes computed over uuid-carrying text differ per run.
    .replaceAllMapped(
      RegExp(r'"([a-zA-Z]*[hH]ash)":"[0-9a-f]{8,}"'),
      (m) => '"${m.group(1)}":"H"',
    )
    // Short per-run record ids (the uuidv7 random tail).
    .replaceAllMapped(
      RegExp(r'"(id|parentId)":"[0-9a-f]{8,}"'),
      (m) => '"${m.group(1)}":"X"',
    );
