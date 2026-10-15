@TestOn('vm')
@Tags(['integration'])
@Timeout(
  Duration(minutes: 6),
) // never clip a wait: budgets sum to ~310 s (gh-1469)
/// Issue #438 AC3 — the over-window badge: a mid-run auto-compaction that
/// frees the window shows «[auto-compacted · continuing]» in the TUI
/// status row while the run continues, and it clears when the turn
/// settles. A fresh follow-up run starts badge-free (E1).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/compaction/structured/judge.dart'
    show hideProtectTailEntries;
import 'package:test/test.dart';
import 'pty_harness.dart';

/// The scenario window (the `contextWindowCap` the test config pins). The
/// cap is LIFTED to 32768 deliberately: at 16384 the PTY stack's ~7.4k
/// request overhead (measured — see [e1FixedOverheadTokens]) is nearly
/// half the window and every scenario shape lands inside the
/// trigger..window dead band, where the E1 follow-up re-enters the
/// compaction chain deterministically (two CI reproductions). At 32768
/// the reserve scales with the window and both compaction lines clear
/// with margins an estimator cannot jitter across.
const scenarioWindow = 32768;

/// The lean-read count: enough reads to overflow [scenarioWindow] (the
/// fold premise) while keeping the post-fold protected-tail floor small.
/// Single edit point shared by the guard, the workspace setup and the
/// mock's scripted reads turn.
const scenarioReadCount = 40;

/// Per-read estimated tokens: 40-char lines + newline over the
/// estimator's chars-per-token basis (token_estimation.dart).
final scenarioPerReadTokens = (90 * 41 / 4).ceil();

/// Fixed per-request overhead MEASURED on the PTY stack (linux hosted
/// runner, the reviewer's reproduction of head 7cb3bd2a4): E1 request
/// basis 12342 tokens with the 30 × 60 shape whose protected tail was
/// 8 × 615 → overhead = 12342 − 8 × 615 = 7422 (system + E1 turn +
/// summary + record projections). Re-measure whenever the scenario shape
/// or the chrome changes — never guess this number.
const e1FixedOverheadTokens = 7422;

void main() {
  // The fold badge carries an optional multiplicity suffix: a slow CI
  // runner can fold twice before the continuation turn streams, rendering
  // «[auto-compacted ×2 · continuing]» — waiting on the exact single-fold
  // string then times out even though the badge is on screen (observed on
  // the pre-merge validation run: 30 s TimeoutException with the ×2 badge
  // visible in the captured screen). Match both forms.
  final foldBadge = RegExp(r'\[auto-compacted( ×\d+)? · continuing\]');

  test('a mid-run fold badges the status row until the turn settles', () async {
    // The scenario's margins, pinned to the production constants they lean
    // on — the /4 char estimator (token_estimation.dart), the protected
    // live-edge tail (hideProtectTailEntries, judge.dart), the
    // shouldCompact trigger (window − reserve, compaction.dart:452,488)
    // and the contextWindowCap floor semantics (cli_config.dart). If any
    // constant moves, this fails HERE with the arithmetic spelled out
    // instead of going red on the nightly with zero gate-time signal.
    final e1Floor =
        hideProtectTailEntries * scenarioPerReadTokens + e1FixedOverheadTokens;
    // CompactionSettings.forWindow: reserve = min(16384, max(1024,
    // window ~/ 4)), degenerate-clamped only below 16384 — at this window
    // the plain quarter wins.
    final shouldCompactTrigger =
        scenarioWindow - (scenarioWindow ~/ 4).clamp(1024, 16384);
    expect(
      scenarioReadCount * scenarioPerReadTokens,
      greaterThan(scenarioWindow),
      reason:
          'the reads turn must still overflow the window — the fold '
          'premise ($scenarioReadCount × $scenarioPerReadTokens = '
          '${scenarioReadCount * scenarioPerReadTokens} vs $scenarioWindow)',
    );
    expect(
      e1Floor,
      lessThan(shouldCompactTrigger - 5000),
      reason:
          'the E1 floor ($e1Floor) must clear the shouldCompact trigger '
          '($shouldCompactTrigger) with wide margin, not just the guard '
          'line — a floor inside the trigger..window dead band re-enters '
          'the compaction chain every run',
    );
    final mock = _FoldingMock();
    await mock.start();
    final tempHome = _tempHomeForMock(mock.port);
    // Forty lean reads in one scripted turn (~36.9k estimated tokens of
    // tool results) blow the 32768-token capped window at the second
    // request — the guard refuses, the compaction folds the older results,
    // the retry continues the turn. The window is LIFTED (not the reads
    // shrunken) so the compaction edges scale away from the fixed
    // overhead: at 16384 the PTY stack's ~7.4k request overhead (measured,
    // see the guard above) is nearly half the window, and every scenario
    // shape lands inside the trigger..window dead band where the E1
    // follow-up re-enters the compaction chain deterministically (two CI
    // reproductions: 13.0k, then 12.3k basis, both over the 12288
    // trigger). At 32768 the reserve doubles with the window
    // (trigger = 24576), the floor (~7k tail + 7.4k overhead ≈ 14.4k)
    // clears it by ~10k, and the reads still overflow by ~4k — no edge
    // left to jitter across, and the E1 badge-free run never enters the
    // compaction chain at all.
    final workspace = Directory('/tmp').createTempSync('fabadge');
    for (var i = 1; i <= scenarioReadCount; i++) {
      File(
        '${workspace.path}/big$i.txt',
      ).writeAsStringSync(List.filled(90, 'x' * 40).join('\n'));
    }
    final harness = await FaCliHarness.spawn(
      workingDirectory: workspace.path,
      extraEnv: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'test-key'},
    );
    addTearDown(() async {
      await harness.close();
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
      await mock.close();
    });

    harness.sendText('count the words');
    harness.sendEnter();

    // The fold prints its receipt — and the badge must ride the status
    // row while the continuation turn streams (the slow final reply
    // widens the window so the frame is always catchable).
    await harness.waitForText(
      '● auto-compacted',
      timeout: const Duration(seconds: 60),
    );
    await harness.waitForText(foldBadge, timeout: const Duration(seconds: 30));

    // Settled: the badge clears from the status row (the receipt stays).
    // 90 s (gh-1469): the turn's tail can ride a bounded relief chain
    // (judge + summarizer + rebuilt request) whose wall-clock budget is
    // minutes by design (issue #541) — a loaded runner legitimately
    // outlives a tighter wait.
    await harness.waitForText(
      'done: recovered',
      timeout: const Duration(seconds: 90),
    );
    await harness.waitForOutput(
      settleMs: 600,
      timeout: const Duration(seconds: 20),
    );
    expect(
      harness.screenText,
      isNot(contains(foldBadge)),
      reason: 'the badge must clear when the turn settles',
    );

    // E1: a fresh run starts badge-free — no fold, no badge. The lean-read
    // shape above leaves E1's floor under the shouldCompact trigger (the
    // static guard at the top pins the margin), so E1 never enters the
    // compaction chain; the 90 s budget (gh-1469) is headroom for a loaded
    // runner, not for a relief chain.
    harness.sendText('say hi');
    harness.sendEnter();
    await harness.waitForText('hi!', timeout: const Duration(seconds: 90));
    await harness.waitForOutput(
      settleMs: 600,
      timeout: const Duration(seconds: 20),
    );
    expect(
      harness.screenText,
      isNot(contains(foldBadge)),
      reason: 'a fresh run without folds must never badge',
    );
  });
}

Directory _tempHomeForMock(int port) {
  final tempHome = Directory.systemTemp.createTempSync('fa_badge_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:$port/v1
mode: code
approvalMode: yolo
allowedTools: [read]
# Pin the classic chrome: this suite asserts the pre-#805 classic status
# row; the band redesign (#805-#807) has its own surface.
tui:
  classic: true
agent:
  contextWindowCap: 32768
''');
  return tempHome;
}

/// A tiny OpenAI-compatible SSE server scripting the fold scenario:
/// agent turns issue `read` tool calls, the hide-judge gets picks, the
/// checkpoint summarizer gets text, and the post-fold continuation reply
/// streams SLOWLY so the badge-on-screen window is catchable.
/// The fold checkpoint summary text — also the dispatch marker for the
/// post-fold continuation request; the reply and the check must never
/// drift apart, or the continuation silently falls through to the reads
/// reply (the gh-1469 starvation class, but silent).
const _foldCheckpoint = 'checkpoint: the word-count investigation';

final class _FoldingMock {
  HttpServer? _server;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
      if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'object': 'list', 'data': []}));
        await request.response.close();
        return;
      }
      if (request.method != 'POST') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();

      // The hide-judge: picks the oldest pairs (validation drops whatever
      // is protected — a no-op hide is fine for the badge scenario).
      if (body.contains('context-hygiene judge')) {
        await _sse(request, [_textChunk('[2]')]);
        return;
      }
      // The checkpoint/classic summarizer: the summary text.
      if (body.contains('<conversation>')) {
        await _sse(request, [_textChunk(_foldCheckpoint)]);
        return;
      }
      // Agent turns, CONTENT-addressed (gh-1469): the over-window guard's
      // relief REPLACES the overflowing request with a rebuilt one, so a
      // fold retry arrives as a fresh request a request-count cannot
      // distinguish — the counter used to hand the next scripted reply to
      // a fold retry and starve the real turn (red run 37962382097: the
      // ×3 fold chain consumed slots until "hi!" never rendered inside
      // its 30 s wait). Dispatch on the payload instead: the E1 ask
      // replies "hi!", a request already carrying the turn-1 checkpoint
      // summary is the post-fold continuation (slow, so the badge frame
      // is catchable), and the only request left is the first turn's
      // reads — every fold retry now re-receives ITS OWN reply.
      if (body.contains('say hi')) {
        await _sse(request, [_textChunk('hi!')]);
        return;
      }
      if (body.contains(_foldCheckpoint)) {
        await _sse(request, [
          _textChunk('done: recovered'),
        ], delay: const Duration(milliseconds: 2500));
        return;
      }
      await _sse(request, [_readsTurnChunk()]);
    });
  }

  Map<String, Object> _textChunk(String text) => {
    'id': 'chatcmpl-x',
    'object': 'chat.completion.chunk',
    'choices': [
      {
        'index': 0,
        'delta': {'role': 'assistant', 'content': text},
        'finish_reason': null,
      },
    ],
  };

  /// One assistant turn with `scenarioReadCount` parallel `read` tool
  /// calls (see the scenario comment in the test body: enough lean reads
  /// to overflow the window while keeping the protected-tail floor
  /// small). Kept in lockstep with the guard's constant — the file-local
  /// [scenarioReadCount] const is the single edit point.
  Map<String, Object> _readsTurnChunk() => {
    'id': 'chatcmpl-x',
    'object': 'chat.completion.chunk',
    'choices': [
      {
        'index': 0,
        'delta': {
          'role': 'assistant',
          'tool_calls': [
            for (var i = 1; i <= scenarioReadCount; i++)
              {
                'index': i - 1,
                'id': 'call_$i',
                'type': 'function',
                'function': {
                  'name': 'read',
                  'arguments': '{"path": "big$i.txt"}',
                },
              },
          ],
        },
        'finish_reason': null,
      },
    ],
  };

  Future<void> _sse(
    HttpRequest request,
    List<Map<String, Object>> chunks, {
    Duration delay = Duration.zero,
  }) async {
    await Future<void>.delayed(delay);
    final response = request.response;
    response.headers.contentType = ContentType('text', 'event-stream');
    for (final chunk in chunks) {
      response.write('data: ${const JsonEncoder().convert(chunk)}\n\n');
    }
    response.write(
      'data: ${const JsonEncoder().convert({
        'id': 'chatcmpl-x',
        'object': 'chat.completion.chunk',
        'choices': [
          {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
        ],
      })}\n\n',
    );
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
