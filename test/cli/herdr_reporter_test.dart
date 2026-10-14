// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The herdr pane reporter's pure contract (issue #1481): the gate truth
/// table (UT-1), the argv builders for every report shape (UT-2), the
/// charset validation + resume-argv rules (UT-3), seq discipline under a
/// fake clock, the closed `--message` label enum, the resume-once-per-
/// session latch, and the fire-and-forget failure contract — nothing is
/// retried, logged, or surfaced.
///
/// Pure unit tier: no CLI instance, no subprocess — the transport arrives
/// as a recording closure.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/cli/herdr_reporter.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:test/test.dart';

/// release() returns a future (the REPL teardown awaits it); this helper
/// keeps the table-driven groups readable.
Future<void> _release(HerdrReporter reporter) => reporter.release();

void main() {
  /// A fully-populated herdr pane environment (the incident session's
  /// shape: herdr 0.8.2, pane `w6:p16`).
  Map<String, String> herdrEnv({
    String env = '1',
    String pane = 'w6:p16',
    String bin = '/opt/homebrew/bin/herdr',
    String? kill,
  }) {
    return {
      'HERDR_ENV': env,
      'HERDR_PANE_ID': pane,
      'HERDR_BIN_PATH': bin,
      'FA_HERDR': ?kill,
    };
  }

  /// Builds a reporter over [env] whose reports land in [sink]. The
  /// recorder completes immediately — a report spawned onto a drained
  /// chain appends SYNCHRONOUSLY at the state()/release() call; reports
  /// from a same-tick burst are serialized behind the in-flight one, so
  /// burst assertions drain first ([drainChain]).
  (HerdrReporter, List<List<String>>) wired(
    Map<String, String> env, {
    DateTime Function()? clock,
    Duration timeout = const Duration(seconds: 2),
  }) {
    final sink = <List<String>>[];
    final reporter = HerdrReporter(
      envLookup: (name) => env[name],
      runProcess: (argv) async {
        sink.add(argv);
      },
      clock: clock,
      timeout: timeout,
    );
    return (reporter, sink);
  }

  /// Lets the delivery chain run down: enough event-loop turns for any
  /// burst of immediately-completing spawns to have recorded.
  Future<void> drainChain() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  int seqOf(List<String> argv) => int.parse(argv[argv.indexOf('--seq') + 1]);

  group('UT-1 gate truth table', () {
    test('fully populated pane env is active', () {
      final (reporter, _) = wired(herdrEnv());
      expect(reporter.active, isTrue);
    });

    test('every unmet condition is inert, alone and combined', () {
      const cases = <String, Map<String, String>>{
        'HERDR_ENV unset': {
          'HERDR_PANE_ID': 'w6:p16',
          'HERDR_BIN_PATH': '/u/b/h',
        },
        'HERDR_ENV not 1': {
          'HERDR_ENV': '0',
          'HERDR_PANE_ID': 'w6:p16',
          'HERDR_BIN_PATH': '/u/b/h',
        },
        'HERDR_ENV blank': {
          'HERDR_ENV': '',
          'HERDR_PANE_ID': 'w6:p16',
          'HERDR_BIN_PATH': '/u/b/h',
        },
        'pane missing': {'HERDR_ENV': '1', 'HERDR_BIN_PATH': '/u/b/h'},
        'pane invalid charset': {
          'HERDR_ENV': '1',
          'HERDR_PANE_ID': 'w6 p16',
          'HERDR_BIN_PATH': '/u/b/h',
        },
        'pane path-shaped': {
          'HERDR_ENV': '1',
          'HERDR_PANE_ID': 'a/b',
          'HERDR_BIN_PATH': '/u/b/h',
        },
        'bin missing': {'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w6:p16'},
        'bin relative': {
          'HERDR_ENV': '1',
          'HERDR_PANE_ID': 'w6:p16',
          'HERDR_BIN_PATH': 'herdr',
        },
        'bin hostile (E7)': {
          'HERDR_ENV': '1',
          'HERDR_PANE_ID': 'w6:p16',
          'HERDR_BIN_PATH': '/tmp/evil.sh; rm -rf /',
        },
        'bin with space': {
          'HERDR_ENV': '1',
          'HERDR_PANE_ID': 'w6:p16',
          'HERDR_BIN_PATH': '/App Support/herdr',
        },
        'kill switch (E8)': {
          'HERDR_ENV': '1',
          'HERDR_PANE_ID': 'w6:p16',
          'HERDR_BIN_PATH': '/u/b/h',
          'FA_HERDR': '0',
        },
      };
      cases.forEach((name, env) {
        final (reporter, _) = wired(env);
        expect(reporter.active, isFalse, reason: name);
      });
    });

    test(
      'kill switch beats a fully-populated herdr env; other values keep it on',
      () {
        expect(
          HerdrReporter.gateActive(
            herdrEnv: '1',
            paneId: 'p',
            binPath: '/h',
            killSwitch: '0',
          ),
          isFalse,
        );
        expect(
          HerdrReporter.gateActive(
            herdrEnv: '1',
            paneId: 'p',
            binPath: '/h',
            killSwitch: 'true',
          ),
          isTrue,
          reason: 'only the literal 0 is the off-switch',
        );
      },
    );
  });

  group('UT-2 argv builders — exact bytes', () {
    test('idle report carries the pinned shape and a ms seq', () {
      final (reporter, sink) = wired(
        herdrEnv(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000123),
      );
      reporter.state(HerdrPaneState.idle);
      const expected = <List<String>>[
        [
          '/opt/homebrew/bin/herdr',
          'pane',
          'report-agent',
          'w6:p16',
          '--source',
          'fa',
          '--agent',
          'fa',
          '--state',
          'idle',
          '--seq',
          '1700000000123',
        ],
      ];
      expect(sink, expected);
    });

    test(
      'working and blocked reports; labels come from a closed enum',
      () async {
        final (reporter, sink) = wired(
          herdrEnv(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
        );
        reporter.state(HerdrPaneState.working);
        reporter.blocked(HerdrBlockedLabel.approval);
        reporter.blocked(HerdrBlockedLabel.ask);
        reporter.blocked(HerdrBlockedLabel.secret);
        reporter.blocked(HerdrBlockedLabel.hostModel);
        await drainChain();
        expect(sink.map((argv) => argv[argv.indexOf('--state') + 1]).toList(), [
          'working',
          'blocked',
          'blocked',
          'blocked',
          'blocked',
        ]);
        String? labelOf(List<String> argv) {
          if (!argv.contains('--message')) return null;
          return argv[argv.indexOf('--message') + 1];
        }

        expect(sink.map(labelOf).toList(), [
          null,
          'approval',
          'ask',
          'secret',
          'host-model',
        ]);
      },
    );

    test('release report', () async {
      final (reporter, sink) = wired(
        herdrEnv(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(5000),
      );
      await _release(reporter);
      const expected = <List<String>>[
        [
          '/opt/homebrew/bin/herdr',
          'pane',
          'release-agent',
          'w6:p16',
          '--source',
          'fa',
          '--agent',
          'fa',
          '--seq',
          '5000',
        ],
      ];
      expect(sink, expected);
    });

    test(
      'session switch re-reports with report-agent-session, never a release',
      () {
        final (reporter, sink) = wired(
          herdrEnv(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(7000),
        );
        reporter.sessionSwitch('173000_ab12');
        expect(sink, hasLength(1));
        const expected = <List<String>>[
          [
            '/opt/homebrew/bin/herdr',
            'pane',
            'report-agent-session',
            'w6:p16',
            '--source',
            'fa',
            '--agent',
            'fa',
            '--agent-session-id',
            '173000_ab12',
            '--seq',
            '7000',
            '--',
            'fa',
            '--session',
            '173000_ab12',
          ],
        ];
        expect(sink, expected);
        expect(sink.where((argv) => argv.contains('release-agent')), isEmpty);
      },
    );

    test('labelFor maps the sealed prompt specs onto the four labels', () {
      expect(
        HerdrReporter.labelFor(
          ApprovalPromptSpec(
            request: ApprovalRequest(
              toolName: 'bash',
              tier: ApprovalTier.exec,
              arguments: const {},
              reason: 'r',
            ),
          ),
        ),
        HerdrBlockedLabel.approval,
      );
      expect(
        HerdrReporter.labelFor(
          AskPromptSpec(header: 'Ask', question: 'q', index: 0, total: 1),
        ),
        HerdrBlockedLabel.ask,
      );
      expect(
        HerdrReporter.labelFor(SecretPromptSpec(name: 'n', reason: 'r')),
        HerdrBlockedLabel.secret,
      );
      expect(
        HerdrReporter.labelFor(const TextPromptSpec(question: 'q')),
        HerdrBlockedLabel.hostModel,
      );
    });

    test(
      'reportSheet reports blocked, then the post-resolve state; answer untouched',
      () async {
        final (reporter, sink) = wired(
          herdrEnv(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(100),
        );
        final answer = await reporter.reportSheet(
          SecretPromptSpec(name: 'n', reason: 'r'),
          open: (spec) async => const TextPromptAnswer('v'),
          busyAfter: () => true,
        );
        expect(answer, isA<TextPromptAnswer>());
        expect(sink.map((argv) => argv[argv.indexOf('--state') + 1]).toList(), [
          'blocked',
          'working',
        ]);
      },
    );

    test('reportSheet resolves to idle when no run is active', () async {
      final (reporter, sink) = wired(
        herdrEnv(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(100),
      );
      await reporter.reportSheet(
        const TextPromptSpec(question: 'pick a host'),
        open: (spec) async => null,
        busyAfter: () => false,
      );
      expect(sink.map((argv) => argv[argv.indexOf('--state') + 1]).toList(), [
        'blocked',
        'idle',
      ]);
    });
  });

  group('UT-3 charset validation + resume-argv rules', () {
    test('pane/session ids accept the pinned charset only', () {
      expect(HerdrReporter.validPaneId('w6:p16'), isTrue);
      expect(HerdrReporter.validPaneId('A.b_9-c'), isTrue);
      expect(HerdrReporter.validPaneId(''), isFalse);
      expect(HerdrReporter.validPaneId('a b'), isFalse);
      expect(HerdrReporter.validPaneId('a/b'), isFalse);
      expect(HerdrReporter.validPaneId("a'b"), isFalse);
      expect(HerdrReporter.validPaneId('a\tb'), isFalse);
      expect(HerdrReporter.validSessionId('173000_ab12.json'), isTrue);
      expect(HerdrReporter.validSessionId('bad id'), isFalse);
    });

    test('bin paths must be absolute and argv-safe', () {
      expect(HerdrReporter.validBinPath('/usr/local/bin/herdr'), isTrue);
      expect(HerdrReporter.validBinPath('/opt/herdr+2/bin/herdr'), isTrue);
      expect(HerdrReporter.validBinPath('herdr'), isFalse, reason: 'relative');
      expect(HerdrReporter.validBinPath('./herdr'), isFalse);
      expect(HerdrReporter.validBinPath(''), isFalse);
      expect(HerdrReporter.validBinPath('/a b/herdr'), isFalse);
      expect(HerdrReporter.validBinPath("/a'b/herdr"), isFalse);
      expect(HerdrReporter.validBinPath(r'/a$b/herdr'), isFalse);
    });

    test(
      'resume argv rules: plain first word, no apostrophes/controls, ≤64 args, ≤8 KiB',
      () {
        expect(
          HerdrReporter.resumeArgvValid(['fa', '--session', 'abc']),
          isTrue,
        );
        expect(HerdrReporter.resumeArgvValid([]), isFalse, reason: 'empty');
        expect(
          HerdrReporter.resumeArgvValid(['/usr/bin/fa', '--session', 'abc']),
          isFalse,
          reason: 'first word must be a plain command name',
        );
        expect(
          HerdrReporter.resumeArgvValid(["fa'x", '--session', 'abc']),
          isFalse,
          reason: 'apostrophes',
        );
        expect(
          HerdrReporter.resumeArgvValid(['fa', '--session', 'a\x01b']),
          isFalse,
          reason: 'control characters',
        );
        expect(
          HerdrReporter.resumeArgvValid(List.filled(65, 'a')),
          isFalse,
          reason: '>64 args',
        );
        expect(
          HerdrReporter.resumeArgvValid(['a' * 9000]),
          isFalse,
          reason: '>8 KiB total',
        );
      },
    );
  });

  group('seq discipline', () {
    test(
      'a frozen clock still yields strictly increasing seq (same-ms reports)',
      () async {
        final (reporter, sink) = wired(
          herdrEnv(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
        reporter.state(HerdrPaneState.idle);
        reporter.state(HerdrPaneState.working);
        reporter.state(HerdrPaneState.idle);
        await drainChain();
        const expected = [1700000000000, 1700000000001, 1700000000002];
        expect(sink.map(seqOf).toList(), expected);
      },
    );

    test(
      'an advancing clock owns the seq; a rollback never decreases it',
      () async {
        var now = 1700000000100;
        final (reporter, sink) = wired(
          herdrEnv(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(now),
        );
        reporter.state(HerdrPaneState.idle);
        now = 1700000000200;
        reporter.state(HerdrPaneState.working);
        now = 1700000000000; // clock rolled back (E2)
        reporter.state(HerdrPaneState.idle);
        await drainChain();
        final seqs = sink.map(seqOf).toList();
        const expected = [1700000000100, 1700000000200, 1700000000201];
        expect(seqs, orderedEquals(expected));
        expect(seqs, everyElement(greaterThanOrEqualTo(seqs.first)));
      },
    );
  });

  group('resume metadata — once per session', () {
    test(
      'first report carrying a session id appends the resume argv; later ones do not',
      () async {
        final (reporter, sink) = wired(
          herdrEnv(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
        );
        reporter.updateSession('173000_ab12');
        reporter.state(HerdrPaneState.idle);
        reporter.state(HerdrPaneState.working);
        await drainChain();
        expect(sink, hasLength(2));
        expect(sink[0].sublist(sink[0].indexOf('--')), [
          '--',
          'fa',
          '--session',
          '173000_ab12',
        ]);
        expect(sink[1].contains('--'), isFalse);
        expect(sink[0].contains('--agent-session-id'), isTrue);
        expect(sink[1].contains('--agent-session-id'), isTrue);
      },
    );

    test(
      'a session switch re-arms the resume argv; a following state report does not repeat it',
      () async {
        final (reporter, sink) = wired(
          herdrEnv(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
        );
        reporter.sessionSwitch('a');
        reporter.state(HerdrPaneState.idle);
        reporter.sessionSwitch('b');
        reporter.state(HerdrPaneState.idle);
        reporter.sessionSwitch('a');
        await drainChain();
        List<String>? resumeBlock(List<String> argv) {
          if (!argv.contains('--')) return null;
          return argv.sublist(argv.indexOf('--'));
        }

        final resumes = sink.map(resumeBlock).toList();
        expect(resumes[0], ['--', 'fa', '--session', 'a']);
        expect(
          resumes[1],
          isNull,
          reason:
              'the state report after a switch carries the id, not the argv',
        );
        expect(resumes[2], ['--', 'fa', '--session', 'b']);
        expect(resumes[3], isNull);
        expect(resumes[4], ['--', 'fa', '--session', 'a']);
      },
    );

    test('a session id that fails the charset never reaches an argv', () {
      final (reporter, sink) = wired(
        herdrEnv(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
      reporter.updateSession("bad'id");
      reporter.state(HerdrPaneState.idle);
      expect(sink.single.contains('--agent-session-id'), isFalse);
      expect(sink.single.contains('--'), isFalse);
    });
  });

  group('resume-argv guard wired into the builders', () {
    // Charset-valid, so `updateSession` adopts it — but it breaks herdr's
    // ≤8 KiB resume-argv rule. The builders must consult the validator
    // before appending the `-- …` tail (defense in depth made real).
    final overlongId = 'a' * 9000;

    test('reportStateArgs drops the resume tail for a rule-breaking id', () {
      final (reporter, _) = wired(herdrEnv());
      final argv = reporter.reportStateArgs(
        state: HerdrPaneState.idle,
        seq: 1,
        sessionId: overlongId,
        includeResumeArgv: true,
      );
      expect(
        argv.contains('--'),
        isFalse,
        reason: 'a rule-breaking resume argv is never appended',
      );
      expect(
        argv.contains('--agent-session-id'),
        isTrue,
        reason:
            'the report itself still goes out (inert on failure only '
            'for the tail)',
      );
    });

    test('sessionSwitchArgs drops the resume tail for a rule-breaking id', () {
      final (reporter, _) = wired(herdrEnv());
      final argv = reporter.sessionSwitchArgs(sessionId: overlongId, seq: 1);
      expect(argv.contains('--'), isFalse);
      expect(argv.contains('--agent-session-id'), isTrue);
    });

    test('the live state() path never emits a rule-breaking tail', () {
      final (reporter, sink) = wired(
        herdrEnv(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
      reporter.updateSession(overlongId);
      reporter.state(HerdrPaneState.idle);
      expect(sink, hasLength(1));
      expect(sink.single.contains('--'), isFalse);
      expect(sink.single.contains('--agent-session-id'), isTrue);
    });
  });

  group('serialized delivery — spawn order follows seq order', () {
    test(
      'a slow report holds the chain; later reports neither overtake nor run concurrently',
      () async {
        final gate = Completer<void>();
        final sent = <List<String>>[];
        final reporter = HerdrReporter(
          envLookup: (name) => herdrEnv()[name],
          runProcess: (argv) {
            sent.add(argv);
            return gate.future;
          },
          clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
        );
        reporter.state(HerdrPaneState.idle);
        reporter.state(HerdrPaneState.working);
        reporter.sessionSwitch('173000_ab12');
        await Future<void>.delayed(Duration.zero);
        expect(
          sent,
          hasLength(1),
          reason:
              'the first (slow) report holds the chain — no later spawn '
              'has even started',
        );
        gate.complete();
        await _release(reporter); // release drains the chain behind the reports
        expect(sent.map((argv) => argv[argv.indexOf('pane') + 1]).toList(), [
          'report-agent',
          'report-agent',
          'report-agent-session',
          'release-agent',
        ]);
        final seqs = sent
            .map((argv) => int.parse(argv[argv.indexOf('--seq') + 1]))
            .toList();
        for (var i = 1; i < seqs.length; i++) {
          expect(
            seqs[i],
            greaterThan(seqs[i - 1]),
            reason: 'delivery order == seq order',
          );
        }
      },
    );
  });

  group('release once-guard', () {
    test('a second release() spawns no second release-agent', () async {
      final (reporter, sink) = wired(
        herdrEnv(),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await _release(reporter);
      await _release(reporter);
      expect(
        sink.where((argv) => argv.contains('release-agent')),
        hasLength(1),
      );
    });

    test(
      'nothing spawns after the release — the registration is gone',
      () async {
        final (reporter, sink) = wired(
          herdrEnv(),
          clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
        );
        await _release(reporter);
        reporter.state(HerdrPaneState.idle);
        reporter.sessionSwitch('173000_ab12');
        expect(sink, hasLength(1), reason: 'only the release report');
        expect(sink.single.contains('release-agent'), isTrue);
      },
    );
  });

  group('fire-and-forget contract', () {
    test(
      'inert reporter: every hook is a no-op and the builders produce no bytes',
      () async {
        final (reporter, sink) = wired({'HERDR_ENV': '1'});
        reporter.updateSession('a');
        reporter.state(HerdrPaneState.idle);
        reporter.blocked(HerdrBlockedLabel.approval);
        reporter.sessionSwitch('a');
        await _release(reporter);
        expect(sink, isEmpty);
        expect(
          reporter.reportStateArgs(state: HerdrPaneState.idle, seq: 1),
          isEmpty,
        );
        expect(reporter.sessionSwitchArgs(sessionId: 'a', seq: 1), isEmpty);
        expect(reporter.releaseArgs(seq: 1), isEmpty);
      },
    );

    test(
      'active gate without a transport: argv built, nothing spawned, no crash',
      () {
        final reporter = HerdrReporter(
          envLookup: (name) => herdrEnv()[name],
          runProcess: null,
        );
        reporter.state(HerdrPaneState.working);
        expect(
          reporter.reportStateArgs(state: HerdrPaneState.working, seq: 1),
          isNotEmpty,
        );
      },
    );

    test('a throwing recorder never propagates', () async {
      final reporter = HerdrReporter(
        envLookup: (name) => herdrEnv()[name],
        runProcess: (argv) async => throw StateError('herdr died'),
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
      reporter.state(HerdrPaneState.idle);
      await _release(reporter);
      expect(reporter.active, isTrue);
    });

    test(
      'a hanging recorder is cut by the timeout and never surfaces',
      () async {
        final reporter = HerdrReporter(
          envLookup: (name) => herdrEnv()[name],
          runProcess: (argv) => Completer<void>().future,
          clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
          timeout: const Duration(milliseconds: 5),
        );
        reporter.state(HerdrPaneState.idle);
        await _release(reporter);
        expect(reporter.active, isTrue);
      },
    );
  });

  group('AC5 exfiltration gate — byte scan over every constructible argv', () {
    // The canary: a secret in the env, a secret in the "transcript", the
    // cwd path. None of them may appear in any argv the reporter builds.
    const canarySecret = 'FA_CANARY_SECRET_VALUE_9f2e';
    const canaryTranscript = 'the model said: paste-token hunter2';
    const canaryCwd = '/Users/somebody/secret-project';

    test('every report shape carries only the pinned vocabulary', () async {
      final (reporter, sink) = wired({
        ...herdrEnv(),
        'HERDR_CANARY_SECRET': canarySecret,
      }, clock: () => DateTime.fromMillisecondsSinceEpoch(1000));
      reporter.updateSession('173000_ab12');
      for (final state in HerdrPaneState.values) {
        reporter.state(state);
      }
      for (final label in HerdrBlockedLabel.values) {
        reporter.blocked(label);
      }
      reporter.sessionSwitch('173000_ab12');
      await _release(reporter);

      expect(sink, isNotEmpty);
      final vocabulary = RegExp(
        r'^(/opt/homebrew/bin/herdr|pane|report-agent|report-agent-session|'
        r'release-agent|w6:p16|--source|--agent|--state|--message|--seq|'
        r'--agent-session-id|--session|fa|idle|working|blocked|approval|ask|'
        r'secret|host-model|173000_ab12|--|\d+)$',
      );
      for (final argv in sink) {
        for (final arg in argv) {
          expect(arg, matches(vocabulary), reason: 'argv: $argv');
        }
        expect(argv.join(' '), isNot(contains(canarySecret)));
        expect(argv.join(' '), isNot(contains(canaryTranscript)));
        expect(argv.join(' '), isNot(contains(canaryCwd)));
      }
    });
  });
}
