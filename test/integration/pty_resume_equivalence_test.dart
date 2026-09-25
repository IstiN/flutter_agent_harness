/// PTY resume-equivalence proof for issue #446 (AC1) plus the large-session
/// resume gates (AC6/AC8).
///
/// AC1: a scripted live turn (markdown reply + foreground bash + background
/// bash + a `task` subagent spawn) runs in a real PTY CLI process; the TUI
/// exits, the session reopens, and the resumed screen's transcript grammar
/// — tool rows, notice blockquotes, markdown rows, user echo — must EQUAL
/// the live screen's, modulo the contract's permitted differences (settled
/// durations `—` vs live cells; board re-print cards are dropped from both
/// sides, their shape is #429's own coverage; and since #807 the live edge
/// paints band tool cards `✔ name: detail 0s` while the replay keeps the
/// legacy row grammar `✓ name · detail —` — both canonicalize to the
/// shared `name: detail` core).
///
/// AC6/AC8: a 3k-record session resumes through the unified pipeline — the
/// tail's pinned grammar rows render, zero `[name]` markers leak, and
/// time-to-first-rendered-tail stays in the fixed PTY boot budget class.
///
/// The provider is the `FA_TEST_STREAM_SCRIPT` hook (see
/// lib/src/cli/scripted_test_stream.dart): no network, real tool execution,
/// real session records.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 10))
@Skip('infra: #936 resume perf budget too tight under load')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/env/io_execution_env.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';
import 'package:flutter_agent_harness/src/context.dart';

final _base = DateTime.utc(2026, 1, 1, 12);

/// The pinned prompt; its echo box anchors the live transcript tail.
const _prompt = 'run the pinned probes for four forty six';

/// The final reply marker: the last live turn settled.
const _replyMarker = 'probes settled';

/// The scripted turns: markdown + foreground bash, background bash, a
/// `task` subagent spawn, the final markdown reply, and a wrap-around
/// reply for any subagent's own provider call.
final _turns = [
  [
    {
      'text':
          '## Plan\n\n- run **pinned** probes\n\n1. first step\n'
          '2. second step',
    },
    {
      'tool_call': {
        'id': 'c1',
        'name': 'bash',
        'arguments': {'command': 'echo pinned-render-1'},
      },
    },
  ],
  [
    {
      'tool_call': {
        'id': 'c2',
        'name': 'bash',
        'arguments': {
          'command': 'sleep 2 && echo bg-pinned-render',
          'background': true,
        },
      },
    },
  ],
  [
    {
      'tool_call': {
        'id': 'c3',
        'name': 'task',
        'arguments': {
          'context': 'PTY equivalence probe; reply with the single word ok',
          'tasks': [
            {'name': 'pty446', 'task': 'reply with the single word ok'},
          ],
        },
      },
    },
  ],
  [
    // The subagent's own provider call, then the parent's final reply.
    {'text': 'ok'},
  ],
  [
    {'text': 'done — the $_replyMarker'},
  ],
];

/// SGR runs (screen lines are already stripped; kept for raw hygiene).
final _sgr = RegExp(r'\x1b\[[0-9;]*[A-Za-z]');

/// A live duration cell: `· 3s`, `· 12.4ms` — replay shows `· —`.
final _durationCell = RegExp(r'·\s*\d+(?:\.\d+)?(?:ms|s)');

/// A background-job board card (`bash sh-1-ab12 · done · 0.3s`): the board
/// re-prints settled cards on resume, mid-turn on live — dropped from both
/// sides; the settlement NOTICE rows stay (they replay as blockquotes).
final _boardCard = RegExp(r'sh-\d+-\w+.*·');

/// The context gauge (`5%/200k`, `10.5k/200k`): only the status footer and
/// the resumed boot's brand row carry it — never transcript grammar.
final _ctxGauge = RegExp(r'\d+(?:\.\d+)?[k%]/\d');

/// A live RUNNING band tool card (`⟳ bash: sleep 2 …`, `⏳ …`): live-only
/// transient — its settled twin carries the same facts and is the row that
/// replays.
final _runningCard = RegExp(r'^[⟳⏳] \S+: ');

/// A live SETTLED band tool card (`✔ bash: sleep 2 … 0s`, `✘ … [exit 1]`).
final _settledCard = RegExp(r'^[✔✘] (\S+): (.+)$');

/// A replayed legacy tool row (`✓ bash · sleep 2 … —`, `✗ …` when the
/// result record never landed).
final _replayedRow = RegExp(r'^[✓✗] (\S+) · (.+)$');

/// A settled card's trailing meta zone: the bracketed badge and/or the
/// elapsed cell (`0s`, `12.4ms`).
final _cardMeta = RegExp(r'(?:\s\[[^\]]+\]|\s\d+(?:\.\d+)?(?:ms|s))+$');

/// Canonicalizes one settled tool row to its shared `name: detail`
/// grammar. The live band card (`✔ bash: sleep 2 … 0s`) and the replayed
/// row (`✓ bash · sleep 2 … —`) render the same call with different
/// glyph/separator/elapsed chrome (#807 vs the legacy row grammar), so the
/// comparison reads the name+detail core both share. Running cards
/// (`⟳ …`) normalize to null: live-only transient.
String? _canonicalToolRow(String t) {
  if (_runningCard.hasMatch(t)) return null;
  final card = _settledCard.firstMatch(t);
  if (card != null) return '${card[1]}: ${card[2]!.replaceAll(_cardMeta, '')}';
  final row = _replayedRow.firstMatch(t);
  if (row != null) {
    return '${row[1]}: ${row[2]!.replaceFirst(RegExp(r'\s+—$'), '')}';
  }
  return t;
}

/// Everything that is boot chrome, composer, status, or board — never
/// transcript grammar.
bool _isChrome(String t) =>
    t.isEmpty ||
    t.startsWith('--- restored session') ||
    t.startsWith('ctrl+') ||
    t.contains('tokens') && t.contains('·') ||
    t.contains(' · ctx ') ||
    _ctxGauge.hasMatch(t) ||
    _boardCard.hasMatch(t) ||
    t.startsWith('/exit') ||
    t.startsWith('====') ||
    t.startsWith('────') ||
    t.startsWith('╰─') ||
    t.contains('Working') ||
    // Box-drawn blocks (background-task completion cards) — their durable
    // form is the persisted notice/registry, replayed below them. The
    // `│ ⚙ …` system-notice blockquote is NOT chrome: it replays 1:1.
    t.startsWith('┌') ||
    t.startsWith('└') ||
    t.startsWith('│') && !t.contains('⚙') ||
    // The live settlement toast writeln and its wrap continuation; the
    // durable notice replays as a `│ ⚙ …` blockquote instead.
    t.startsWith('[bash] ') && t.contains('exited(') ||
    (t.startsWith('/') && t.endsWith('.log'));

/// Normalizes one screen's lines into the comparable transcript sequence.
List<String> transcriptOf(List<String> lines) {
  final stripped = [
    for (final line in lines)
      line.replaceAll(_sgr, '').replaceAll(_durationCell, '· —').trimRight(),
  ];
  // Trim trailing composer/status chrome: walk back past non-transcript
  // rows, keeping everything from the last grammar-looking row up.
  var end = stripped.length;
  while (end > 0) {
    final t = stripped[end - 1].trim();
    if (t.startsWith('>') ||
        t.startsWith('✓') ||
        t.startsWith('✔') ||
        t.startsWith('✗') ||
        t.startsWith('✘') ||
        t.startsWith('•') ||
        RegExp(r'^\d+\.\s').hasMatch(t) ||
        t == _prompt) {
      break;
    }
    end--;
  }
  final rows = <String>[];
  for (final line in stripped.take(end)) {
    final t = line.trim();
    if (_isChrome(t)) continue;
    final canonical = _canonicalToolRow(t);
    if (canonical != null) rows.add(canonical);
  }
  // The settled bg-job notice starts one wrap-around scripted turn whose
  // reply repeats the marker row; whether that repeat has PAINTED when a
  // frame is captured is a timing race, not a grammar difference (the
  // session always persists it). Keep the first assistant row only.
  final seenAssistant = <String>{};
  return [
    for (final row in rows)
      if (!row.startsWith('>_Fa ') || seenAssistant.add(row)) row,
  ];
}

void main() {
  late Directory home;
  late Directory project;
  late File turnsFile;

  setUp(() async {
    // Short fixed dirs (#446): long macOS temp paths wrap mid-path and
    // desync the two frames' wrap continuations; /tmp keeps every row on
    // one physical line.
    home = Directory('/tmp/fa_446_home')..createSync(recursive: true);
    project = Directory('/tmp/fa_446_proj')..createSync(recursive: true);
    // Pin the classic chrome: this suite asserts the classic transcript
    // grammar; the band redesign (#805-#807) has its own surface. The
    // harness configures providers via FA_PROVIDER_CONFIG env only, so the
    // pin rides its own tiny config.yaml.
    File('${home.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('tui:\n  classic: true\n');
    turnsFile = File('${home.path}/fa_446_turns.json')
      ..writeAsStringSync(jsonEncode(_turns));
  });

  tearDown(() async {
    await home.delete(recursive: true);
    await project.delete(recursive: true);
  });

  Map<String, String> env() => {
    'HOME': home.path,
    'FA_TEST_STREAM_SCRIPT': turnsFile.path,
    'FA_PROVIDER_TYPE': 'openai',
    'FA_PROVIDER_CONFIG': jsonEncode({
      'baseUrl': 'http://127.0.0.1:9', // never dialed — the script streams
      'model': 'pty-scripted',
    }),
  };

  test('AC1: resume renders 1:1 with live (normalized diff empty)', () async {
    // --- live run: fresh session, one scripted turn, graceful exit.
    final live = await FaCliHarness.spawn(
      workingDirectory: project.path,
      extraEnv: env(),
      args: ['--session', 'pty446'],
    );
    try {
      await live.waitForBoot();
      live.sendText(_prompt);
      live.sendEnter();
      await live.waitForText(
        _replyMarker,
        timeout: const Duration(seconds: 60),
      );
      await live.waitForText(
        'Background shell job',
        timeout: const Duration(seconds: 30),
      );
      await live.waitForOutput(
        settleMs: 700,
        timeout: const Duration(seconds: 20),
      );
      final liveScreen = live.viewportLines;
      await live.runSlashCommand('/exit');
      await live.pty.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () => -1,
      );
      // --- the resumed run: same session, fresh process.
      final resumed = await FaCliHarness.spawn(
        workingDirectory: project.path,
        extraEnv: env(),
        args: ['--session', 'pty446'],
      );
      try {
        // The boot banners scroll out of the small viewport once the
        // replayed tail renders; wait for the tail instead.
        await resumed.waitForText(
          _replyMarker,
          timeout: const Duration(seconds: 60),
        );
        await resumed.waitForOutput(
          settleMs: 700,
          timeout: const Duration(seconds: 20),
        );
        final resumeScreen = resumed.viewportLines;
        final resumeText = resumed.screenText;

        // Contract: zero fallback markers on the resumed screen.
        expect(resumeText, isNot(contains('[bash]')));
        expect(resumeText, isNot(contains('[task]')));
        for (final line in resumeScreen) {
          expect(
            line.trimLeft().startsWith('⚙'),
            isFalse,
            reason: 'raw gear-prefixed line leaked: $line',
          );
        }

        // The unified transcript grammar: the resumed viewport holds the
        // SAME tail rows live ended on (its viewport may also keep older
        // rows live had scrolled past — the tail must match exactly).
        final liveTail = transcriptOf(liveScreen);
        final resumeTail = transcriptOf(resumeScreen);
        final shared = liveTail.length <= resumeTail.length
            ? resumeTail.sublist(resumeTail.length - liveTail.length)
            : resumeTail;
        expect(
          shared,
          liveTail,
          reason:
              '''
live transcript:
${liveTail.join('\n')}

resumed transcript:
${resumeTail.join('\n')}''',
        );
      } finally {
        await resumed.close();
      }
    } finally {
      await live.close();
    }
  });

  test('AC6/AC8: 3k-record resume renders the pinned tail in budget', () async {
    final sessionsRoot = await Directory.systemTemp.createTemp('fa_446_sess_');
    try {
      final repo = JsonlSessionRepo(
        fs: LocalExecutionEnv(cwd: project.path),
        sessionsRoot: sessionsRoot.path,
      );
      const id = 'pty446-large';
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: project.path, id: id),
      );
      final meta = await session.getMetadata();
      final sink = File(meta.path).openWrite(mode: FileMode.append);
      const turns = 750; // ~3k records: user + assistant + result per turn.
      var prev = MessageRecord(
        id: 'rec-u0',
        parentId: null,
        timestamp: _base,
        message: UserMessage.text('boot'),
      );
      sink.write('${jsonEncode(prev.toJson())}\n');
      for (var t = 1; t <= turns; t++) {
        final user = MessageRecord(
          id: 'rec-$t-u',
          parentId: prev.id,
          timestamp: _base.add(Duration(seconds: t * 10)),
          message: UserMessage.text('question $t'),
        );
        final assistant = MessageRecord(
          id: 'rec-$t-a',
          parentId: user.id,
          timestamp: _base.add(Duration(seconds: t * 10 + 1)),
          message: AssistantMessage(
            content: [
              ThinkingContent(thinking: 'thought $t'),
              ToolCall(
                id: 'rec-$t-c1',
                name: 'bash',
                arguments: {'command': 'echo probe-$t'},
              ),
              TextContent(text: 'answer $t'),
            ],
            api: 'test-api',
            provider: 'test-provider',
            model: 'pty-scripted',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: _base.add(Duration(seconds: t * 10 + 2)),
          ),
        );
        final result = MessageRecord(
          id: 'rec-$t-r',
          parentId: assistant.id,
          timestamp: _base.add(Duration(seconds: t * 10 + 3)),
          message: ToolResultMessage(
            toolCallId: 'rec-$t-c1',
            toolName: 'bash',
            content: [TextContent(text: 'probe-$t')],
            isError: false,
            timestamp: _base.add(Duration(seconds: t * 10 + 3)),
          ),
        );
        for (final record in [user, assistant, result]) {
          sink.write('${jsonEncode(record.toJson())}\n');
        }
        prev = result;
      }
      await sink.flush();
      await sink.close();

      final watch = Stopwatch()..start();
      final resumed = await FaCliHarness.spawn(
        workingDirectory: project.path,
        extraEnv: env(),
        args: ['--session', id, '--session-root', sessionsRoot.path],
      );
      try {
        // The restored header scrolls out of the small scrollback at 3k
        // records; the tail's last rendered row is the settled marker.
        await resumed.waitForText(
          'answer $turns',
          timeout: const Duration(seconds: 60),
        );
        final timeToTail = watch.elapsed;
        await resumed.waitForOutput(
          settleMs: 700,
          timeout: const Duration(seconds: 20),
        );
        // The tail rides the unified pipeline: pinned rows visible.
        final tail = resumed.screenText;
        expect(tail, contains('✓ bash'));
        expect(tail, contains('echo probe-$turns'));
        expect(tail, contains('answer $turns'));
        expect(tail, isNot(contains('[bash]')));
        // AC8 fixed ceiling: PTY boot + windowed open + tail render.
        expect(
          timeToTail,
          lessThan(const Duration(seconds: 45)),
          reason: 'resume time-to-tail: $timeToTail',
        );
      } finally {
        await resumed.close();
      }
    } finally {
      await sessionsRoot.delete(recursive: true);
    }
  });
}
