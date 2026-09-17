/// PTY proof for issue #599: a background job whose command is a 60-line
/// heredoc must never spill its body into the transcript.
///
/// RED contract (the owner frame): before the fix the settle notice echoes
/// the whole multi-line command through the system-notice renderer — ~60
/// gray `> ⚙` transcript rows, the heredoc body readable on the glass.
/// After the fix:
///
/// - the heredoc body is never a transcript row source (E1: whether or not
///   the `EOF` terminator appears, the preview is one line + `…`);
/// - exactly ONE bounded settle card: ≤ 6 body rows plus the
///   `… N more — bash_job output <id>` overflow hint;
/// - the viewport pages over any-height transcript content and the
///   composer/status zone stays reserved in every scrolled position.
///
/// The provider is the `FA_TEST_STREAM_SCRIPT` hook: no network, real tool
/// execution, real session records.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

const _reply = 'heredoc job launched for pty599';

/// A line unique to the heredoc BODY — its presence on any paged frame is
/// the spill the owner reported.
const _bodyMarker = 'heredoc body line 17 must never reach the glass';

/// 60 physical lines: the heredoc opener, 58 body lines, the `EOF`
/// terminator. Written to a file in the job's cwd (real execution).
final _heredocCommand = [
  "cat > heredoc-target.md << 'EOF'",
  for (var i = 1; i <= 58; i++)
    i == 17 ? _bodyMarker : 'heredoc body line $i padding the command',
  'EOF',
].join('\n');

final _turns = [
  [
    {'text': 'launching the heredoc job'},
    {
      'tool_call': {
        'id': 'c1',
        'name': 'bash',
        'arguments': {'command': _heredocCommand, 'background': true},
      },
    },
  ],
  [
    {'text': _reply},
  ],
];

void main() {
  late Directory home;
  late Directory project;
  late File turnsFile;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('fa_599_home_');
    project = await Directory.systemTemp.createTemp('fa_599_proj_');
    turnsFile = File('${home.path}/fa_599_turns.json')
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

  /// The composer's reserved bottom rows: the full-width rule directly
  /// above the status row (nothing may paint into that zone).
  void expectComposerReserved(List<String> viewport, int columns) {
    expect(viewport, isNotEmpty);
    final status = viewport.last;
    expect(
      status,
      contains('· ctx '),
      reason:
          'the status row is the frame\'s last row — nothing painted '
          'below it:\n${viewport.join('\n')}',
    );
    final rule = viewport[viewport.length - 2];
    expect(
      rule,
      '─' * columns,
      reason:
          'the input zone\'s lower rule is full-width and in place:\n'
          '${viewport.join('\n')}',
    );
  }

  test('60-line heredoc job: bounded card, body never rendered, viewport '
      'pages over the block with the composer reserved', () async {
    final harness = await FaCliHarness.spawn(
      workingDirectory: project.path,
      extraEnv: env(),
      args: ['--session', 'pty599-heredoc'],
      columns: 80,
      rows: 24,
    );
    addTearDown(harness.close);

    // The JIT frontend needs >60s cold on slow single-host CI boxes — the
    // boot budget rides the harness default of 90s nowhere; give it room.
    await harness.waitForBoot(timeout: const Duration(minutes: 5));

    // ── spawn the background heredoc job and wait for its settle ───────
    harness.sendText('run the heredoc job');
    harness.sendEnter();
    await harness.waitForText(
      'completed in background',
      timeout: const Duration(minutes: 2),
    );
    await harness.waitForOutput(settleMs: 500);

    // ── page to the top of the scrollback, collecting every frame ──────
    final paged = <String>[];
    for (var i = 0; i < 10; i++) {
      harness.sendText('\x1b[5~'); // pgup
      await Future<void>.delayed(const Duration(milliseconds: 90));
      paged.add(harness.screenText);
      expectComposerReserved(harness.viewportLines, 80);
    }
    final pagedText = paged.join('\n');

    // RED: pre-fix the settle notice echoes the whole heredoc — the body
    // lands on the glass as ~60 gray rows. Post-fix the body is never a
    // transcript row source (E1: terminator or not, the preview is one
    // line + `…`).
    expect(
      pagedText,
      isNot(contains(_bodyMarker)),
      reason:
          'the heredoc body must never render as transcript rows:\n'
          '$pagedText',
    );
    final gearRows = <String>{
      for (final frame in paged)
        for (final line in frame.split('\n'))
          if (line.contains('⚙')) line,
    };
    expect(
      gearRows.length,
      lessThanOrEqualTo(12),
      reason:
          'the settle notice stays a bounded blockquote — a 60-line '
          'command may not flood it:\n${gearRows.join('\n')}',
    );

    // ── page back down: exactly ONE bounded settle card ────────────────
    for (var i = 0; i < 12; i++) {
      harness.sendText('\x1b[6~'); // pgdown
      await Future<void>.delayed(const Duration(milliseconds: 90));
    }
    await harness.waitForScreen(
      'bash task completed in background',
      timeout: const Duration(minutes: 2),
    );
    final bottom = harness.screenText;
    expectComposerReserved(harness.viewportLines, 80);

    // ONE card, bounded: the first command line + the overflow hint.
    expect(
      'bash task completed in background'.allMatches(bottom),
      hasLength(1),
      reason: 'exactly one settle card:\n$bottom',
    );
    expect(
      bottom,
      contains("cat > heredoc-target.md << 'EOF'"),
      reason: 'the card previews the command\'s first line:\n$bottom',
    );
    expect(
      bottom,
      contains('… 59 more — bash_job output'),
      reason:
          'the card carries the bounded-body overflow hint with the '
          'bash_job pointer:\n$bottom',
    );
    final cardRows = bottom
        .split('\n')
        .skipWhile((l) => !l.contains('bash task completed'))
        .takeWhile((l) => !l.startsWith('└─'))
        .where((l) => l.startsWith('│'))
        .toList();
    expect(
      cardRows.length,
      lessThanOrEqualTo(6),
      reason: 'card body stays ≤ 6 rows:\n${cardRows.join('\n')}',
    );
    expect(
      bottom,
      isNot(contains('heredoc body line')),
      reason: 'no heredoc body line renders, on any row:\n$bottom',
    );

    await harness.runSlashCommand('/exit');
    await harness.pty.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () => -1,
    );
  });
}
