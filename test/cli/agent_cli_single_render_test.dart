/// gh-1931 — one render per tool call on every console surface.
///
/// The non-TUI console (line mode + headless log) printed every executed
/// tool call TWICE: a start row (`• label · detail`, no elapsed) from
/// `_onToolExecutionStart` followed by an end row (`✓/✗ label · detail
/// Ns`) from `_onToolExecutionEnd`. The end row already carries everything
/// the start row said (detail = command, status glyph, elapsed; failure
/// text on error), so the start row was a pure duplicate print — the bug
/// YuryBY reported ("a tool row with elapsed time plus a redundant second
/// print without it").
///
/// These tests pin the fix at the byte level:
/// - AC1 line mode: command string once, elapsed marker once (golden).
/// - AC3 headless: new log == OLD log minus ONLY the duplicated start rows
///   (no new losses, no reordering) — command, status, elapsed, failure
///   marker each exactly once.
/// - AC4 success AND failure paths single-rendered; the `!cmd` local-exec
///   branch stays single-rendered.
/// - AC2 the TUI keeps its running card (the transcript grammar is a
///   non-goal — the dedupe must not leak past the non-TUI branch).
/// - AC5 the session JSONL keeps the full call + result records.
/// - E1/E2/E4: multi-line command truncated once, background job settle
///   notices survive, empty-output calls still render exactly one row.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
// LocalExecutionEnv is a VM-only surface (dart:io-backed) — it ships via
// the io.dart barrel, not the platform-neutral one.
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/cli/tool_row_content.dart';
import 'package:flutter_agent_harness/src/cli/tool_rows.dart';
import 'package:flutter_agent_harness/src/cli/tui_chrome.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The unpainted console row the non-TUI surface prints (no theme profile
/// in tests → `tuiToolRow` returns `│ ${row.join()}`).
String _row(ToolRowSegments segments, ToolRowState state) =>
    tuiToolRow(layoutToolRow(segments, -2), state);

/// The tool-row lines of a captured console/log channel. Line mode prints
/// the first row after the `fa> ` prompt on the same physical line — the
/// prompt prefix is stripped so the row bytes compare exactly.
List<String> _rowLines(String channel) => channel
    .split('\n')
    .map(
      (line) => line.startsWith('fa> ') ? line.substring('fa> '.length) : line,
    )
    .where((line) => line.startsWith('│ '))
    .toList();

AgentCli _cli(
  CliIO io, {
  ExecutionEnv? env,
  List<AssistantMessageEvent>? turn1,
  String turn2 = 'done',
}) {
  return AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env ?? MemoryExecutionEnv(cwd: '/work', shell: FakeShell()),
      sessionRoot: '/sessions',
      approvalMode: ApprovalMode.yolo,
      skillsAccess: SkillsAccess.granted,
    ),
    io: io,
    streamFunction: FakeStreamFunction([?turn1, textTurn(turn2)]).call,
  );
}

void main() {
  test(
    'AC1: line mode renders a bash call exactly once — command and elapsed '
    'each appear once, no start row (golden)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final shell = FakeShell(stdout: 'hello-out');
      final cli = _cli(
        io,
        env: MemoryExecutionEnv(cwd: '/work', shell: shell),
        turn1: toolTurn(const [
          ToolCall(id: 't1', name: 'bash', arguments: {'command': 'echo hi'}),
        ]),
      );
      final run = cli.run();
      io.sendLine('run a bash call');
      await waitForIt(
        () => io.out.toString().contains('done'),
        reason: 'the turn settled with the final text',
      );

      final rows = _rowLines(io.out.toString());
      // Exactly ONE row for the call: the end row with the elapsed cell —
      // the old start row (`│ • bash · echo hi`) is gone.
      expect(rows, [
        _row(
          const ToolRowSegments(
            glyph: '✓',
            label: 'bash',
            detail: 'echo hi',
            elapsed: '0s',
          ),
          ToolRowState.done,
        ),
      ], reason: '--- console output ---\n${io.out}');
      expect(
        io.out.toString().contains('│ • '),
        isFalse,
        reason: 'the running-glyph start row was the duplicate print',
      );
      // The command really executed through the env (the row describes a
      // real run, not a synthetic event).
      expect(shell.commands, contains('echo hi'));

      await run.timeout(const Duration(seconds: 10), onTimeout: () {});
      await io.close();
    },
  );

  test(
    'AC4: line mode failure path renders exactly once — the failure marker '
    'and its news stay on the single end row',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final cli = _cli(
        io,
        env: MemoryExecutionEnv(
          cwd: '/work',
          shell: FakeShell(stdout: 'boom-out', stderr: 'boom-err', exitCode: 3),
        ),
        turn1: toolTurn(const [
          ToolCall(id: 't1', name: 'bash', arguments: {'command': 'false'}),
        ]),
      );
      final run = cli.run();
      io.sendLine('run a failing bash call');
      await waitForIt(
        () => io.out.toString().contains('done'),
        reason: 'the turn settled with the final text',
      );

      final rows = _rowLines(io.out.toString());
      expect(rows, [
        _row(
          const ToolRowSegments(
            glyph: '✗',
            label: 'bash',
            detail: 'Tool error (bash): boom-out',
            elapsed: '0s',
          ),
          ToolRowState.failed,
        ),
      ], reason: '--- console output ---\n${io.out}');
      expect(io.out.toString().contains('│ • '), isFalse);

      await run.timeout(const Duration(seconds: 10), onTimeout: () {});
      await io.close();
    },
  );

  test(
    'AC3: headless log == OLD output minus ONLY the duplicated start rows '
    '(byte property, success + failure)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Success leg.
      final io = SplitChannelCliIO();
      final cli = _cli(
        io,
        env: MemoryExecutionEnv(
          cwd: '/work',
          shell: FakeShell(stdout: 'hello-out'),
        ),
        turn1: toolTurn(const [
          ToolCall(id: 't1', name: 'bash', arguments: {'command': 'echo hi'}),
        ]),
      );
      final exit = await cli.runHeadless('run a bash call');
      expect(exit, 0);

      final startRow = _row(
        const ToolRowSegments(glyph: '•', label: 'bash', detail: 'echo hi'),
        ToolRowState.running,
      );
      final endRow = _row(
        const ToolRowSegments(
          glyph: '✓',
          label: 'bash',
          detail: 'echo hi',
          elapsed: '0s',
        ),
        ToolRowState.done,
      );
      // The OLD log for this call was [startRow, endRow]; the new log must
      // be OLD minus the duplicated start rows — order and bytes kept.
      final oldLines = [startRow, endRow];
      final deduped = oldLines
          .where((line) => !line.startsWith('│ • '))
          .toList();
      final rows = _rowLines(io.diag.toString());
      expect(rows, deduped, reason: '--- headless log ---\n${io.diag}');
      // Command once, status once, elapsed once — the log is grep-stable.
      expect('echo hi'.allMatches(io.diag.toString()), hasLength(1));
      expect(io.diag.toString().contains('│ • '), isFalse);
      expect('0s'.allMatches(io.diag.toString()), hasLength(1));

      // Failure leg: the same property with the failure marker row.
      final failIo = SplitChannelCliIO();
      final failCli = _cli(
        failIo,
        env: MemoryExecutionEnv(
          cwd: '/work',
          shell: FakeShell(stdout: 'boom-out', stderr: 'boom-err', exitCode: 3),
        ),
        turn1: toolTurn(const [
          ToolCall(id: 't1', name: 'bash', arguments: {'command': 'false'}),
        ]),
      );
      await failCli.runHeadless('run a failing bash call');
      final failStart = _row(
        const ToolRowSegments(glyph: '•', label: 'bash', detail: 'false'),
        ToolRowState.running,
      );
      final failEnd = _row(
        const ToolRowSegments(
          glyph: '✗',
          label: 'bash',
          detail: 'Tool error (bash): boom-out',
          elapsed: '0s',
        ),
        ToolRowState.failed,
      );
      final failRows = _rowLines(failIo.diag.toString());
      expect(failRows, [
        failEnd,
      ], reason: '--- headless log ---\n${failIo.diag}');
      expect(
        failIo.diag.toString(),
        isNot(contains(failStart)),
        reason: 'the start row must be the ONLY thing removed',
      );
      // The failure news (the tail-capped embed surface) stays on the row.
      expect(failIo.diag.toString(), contains('Tool error (bash): boom-out'));
    },
  );

  test(
    'E1+E4: a multi-line command and an empty-output call each render ONE '
    'row — truncation applies to the single render',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final cli = _cli(
        io,
        env: MemoryExecutionEnv(
          cwd: '/work',
          shell: FakeShell(stdout: ''),
        ),
        turn1: toolTurn(const [
          ToolCall(
            id: 't1',
            name: 'bash',
            arguments: {'command': 'echo one\necho two'},
          ),
          ToolCall(id: 't2', name: 'bash', arguments: {'command': 'silent'}),
        ]),
      );
      final run = cli.run();
      io.sendLine('run two bash calls');
      await waitForIt(
        () => io.out.toString().contains('done'),
        reason: 'the turn settled with the final text',
      );

      final rows = _rowLines(io.out.toString());
      // Heredoc-aware preview: first line + … (issue #599) — once per call,
      // no per-duplicate truncation.
      expect(rows, [
        _row(
          const ToolRowSegments(
            glyph: '✓',
            label: 'bash',
            detail: 'echo one…',
            elapsed: '0s',
          ),
          ToolRowState.done,
        ),
        _row(
          const ToolRowSegments(
            glyph: '✓',
            label: 'bash',
            detail: 'silent',
            elapsed: '0s',
          ),
          ToolRowState.done,
        ),
      ], reason: '--- console output ---\n${io.out}');

      await run.timeout(const Duration(seconds: 10), onTimeout: () {});
      await io.close();
    },
  );

  test(
    'AC4 !branch: the local `!cmd` exec stays single-rendered — its output '
    'prints once and no tool rows join',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final cli = _cli(
        io,
        env: MemoryExecutionEnv(
          cwd: '/work',
          shell: FakeShell(stdout: 'bang-marker'),
        ),
      );
      final run = cli.run();
      io.sendLine('!echo bang-marker');
      await waitForIt(
        () => io.out.toString().contains('bang-marker'),
        reason: 'the local exec printed its stdout',
      );
      await run.timeout(const Duration(seconds: 10), onTimeout: () {});
      await io.close();

      final out = io.out.toString();
      expect('bang-marker'.allMatches(out), hasLength(1));
      // exit 0 → no exit-code line; and the exec path never prints rows.
      expect(out.contains('exit code:'), isFalse);
      expect(
        out.contains('│ '),
        isFalse,
        reason: 'the local exec path never prints tool rows',
      );
    },
  );

  test(
    'E2: a backgrounded bash call keeps its distinct settle event next to '
    'the single end row',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final taskDir = await Directory.systemTemp.createTemp('fa_single_render');
      final artifactsDir = await Directory.systemTemp.createTemp(
        'fa_single_render_art',
      );
      addTearDown(() async {
        await taskDir.delete(recursive: true);
        await artifactsDir.delete(recursive: true);
      });
      final io = SplitChannelCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: LocalExecutionEnv(cwd: taskDir.path),
          sessionRoot: '${artifactsDir.path}/sessions',
          approvalMode: ApprovalMode.yolo,
          jobLogDir: '${artifactsDir.path}/bash_jobs',
        ),
        io: io,
        streamFunction: FakeStreamFunction([
          toolTurn(const [
            ToolCall(
              id: 'c1',
              name: 'bash',
              arguments: {'command': 'echo bg-marker', 'background': true},
            ),
          ]),
          textTurn('started the background job'),
          textTurn('noted the background settle'),
        ]).call,
      );
      final exit = await cli.runHeadless('start a background echo job');
      expect(exit, 0);
      await waitForIt(
        () => io.diag.toString().contains('exited('),
        reason: 'the job settle notice reached the log',
      );

      final rows = _rowLines(io.diag.toString());
      // One TOOL row for the call; no running-glyph start row. The settle
      // CARD (`┌─ bash task completed in background …`) is a separate
      // event (gh-1835 semantics) and must survive the dedupe.
      expect(rows.where((line) => line.startsWith('│ • ')), isEmpty);
      expect(
        rows.where((line) => line.contains(' bash · ')).length,
        1,
        reason: '--- log ---\n${io.diag}',
      );
      expect(io.diag.toString(), contains('[bash] sh-'));
      expect(io.diag.toString(), contains('exited('));
    },
  );

  test(
    'AC5: the session JSONL keeps the full call + result records '
    '(rendering-only fix — persistence untouched)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final taskDir = await Directory.systemTemp.createTemp('fa_single_render');
      final artifactsDir = await Directory.systemTemp.createTemp(
        'fa_single_render_art',
      );
      addTearDown(() async {
        await taskDir.delete(recursive: true);
        await artifactsDir.delete(recursive: true);
      });
      final io = SplitChannelCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: LocalExecutionEnv(cwd: taskDir.path),
          sessionRoot: '${artifactsDir.path}/sessions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: io,
        streamFunction: FakeStreamFunction([
          toolTurn(const [
            ToolCall(id: 't1', name: 'bash', arguments: {'command': 'echo hi'}),
          ]),
          textTurn('done'),
        ]).call,
      );
      await cli.runHeadless('run a bash call');

      final sessionsDir = Directory('${artifactsDir.path}/sessions');
      final jsonlFiles = sessionsDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .toList();
      expect(jsonlFiles, hasLength(1));
      final jsonl = jsonlFiles.single.readAsStringSync();
      // The call record (args) and the result record (real exec output —
      // LocalExecutionEnv runs the command) both persist as before.
      expect(jsonl, contains('"name":"bash"'));
      expect(jsonl, contains('"command":"echo hi"'));
      expect(jsonl, contains('"role":"toolResult"'));
      expect(jsonl, contains('"text":"hi'));
    },
  );

  test(
    'AC2: the live TUI still paints the running card at the start edge — '
    'the dedupe never leaks past the non-TUI branch (REG golden-card guard)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      addTearDown(keys.close);
      final shell = FakeShell(stdout: 'hi');
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final io = FakeCliIO();
      final config = AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
        skillsAccess: SkillsAccess.granted,
        tuiProgramHooks: TuiProgramHooks(
          input: keys.stream,
          output: frames,
          width: 80,
          height: 24,
        ),
      );
      final cli = AgentCli(
        config: config,
        io: io,
        useTui: true,
        streamFunction: FakeStreamFunction([
          toolTurn([
            const ToolCall(
              id: 't1',
              name: 'bash',
              arguments: {'command': 'echo hi'},
            ),
          ]),
          textTurn('done'),
        ]).call,
      );
      final run = cli.run();
      try {
        await waitForIt(
          () => frames.text.contains('\x1b[?1049h'),
          reason: 'the TUI boot reached the frame renderer',
        );
        keys.add(utf8.encode('hi'));
        keys.add([0x0d]);
        await waitForIt(
          () => _normalize(frames.text).contains('done'),
          reason: 'the turn settled with the final text',
        );

        // The TUI start edge is UNCHANGED: the running card is still
        // painted (gh-1931 only removes the non-TUI duplicate row).
        final runningCard = tuiToolCard(
          const ToolCardSegments(title: 'bash', description: 'echo hi'),
          TuiCardPhase.running,
          80,
        );
        expect(
          _normalize(frames.text),
          contains(_normalize(runningCard.join('\n'))),
          reason: 'the TUI keeps its running card — frames=${frames.text}',
        );
        // ...and the settled card still lands on the end edge — the SAME
        // shared builder the live edge feeds, fed through the gh-1933 v2
        // derivation ([settledCallCardRows]: bash intent detail, output
        // lines meta, right elapsed zone, dim command preview) so the
        // golden can never drift from the real call site.
        final settled = settledCallCardRows(
          toolName: 'bash',
          args: const {'command': 'echo hi'},
          resultContent: [const TextContent(text: 'hi\n')],
          isError: false,
          width: 80,
          elapsed: '0s',
          cwd: '/work',
          home: config.homeDir,
        );
        // The frame capture carries the rows joined by cursor-positioning
        // (diff paint) — no literal newline survives _normalize, so the
        // multi-row v2 card is asserted row-by-row.
        for (final row in settled) {
          expect(
            _normalize(frames.text),
            contains(_normalize(row)),
            reason: 'the settled card row landed — frames=${frames.text}',
          );
        }
        expect(shell.commands, contains('echo hi'));
      } finally {
        keys.add([0x03]);
        keys.add([0x03]);
        await run.timeout(const Duration(seconds: 10), onTimeout: () {});
        await io.close();
        await keys.close();
      }
    },
  );
}

/// Collects rendered frame bytes (dart_tui wraps this into an IOSink).
class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}

/// SGR + cursor/control sequences out, then runs of spaces collapsed: the
/// alt-screen renderer may emit a row as diff spans, so the visible-cells
/// comparison rides normalized text.
String _normalize(String s) => s
    .replaceAll(RegExp('\x1b\\[[0-9;?]*[a-zA-Z]'), '')
    .replaceAll(RegExp(' +'), ' ');
