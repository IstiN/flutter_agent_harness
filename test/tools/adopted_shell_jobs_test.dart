/// Issue #2201: detached background processes (`cmd &`, nohup) left behind
/// by a foreground bash call are DETECTED at exit, ADOPTED into the job
/// registry as liveness-only jobs, their completion is NOTIFIED through the
/// settle path, and boot re-adopts previous-run manifest entries.
///
/// Layers covered here: the pure survivor classification (group scan +
/// orphan-window heuristic), the registry adoption API + liveness poll
/// (fake probe/kill seams), the `bash_job` renderers' honest adopted
/// shapes (driven through the real tool), the notice texts, the
/// description platform gate — and, on POSIX, the real-process exec and
/// registry-job paths (AC1/AC7).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/env/process_probe_io.dart';
import 'package:test/test.dart';

/// A minimal process-capable env so a registry reports `isSupported` —
/// the shell_jobs_test pattern, trimmed to what adoption touches.
final class _FakeBackgroundEnv implements ExecutionEnv, BackgroundShell {
  final MemoryExecutionEnv _delegate = MemoryExecutionEnv(cwd: '/w');

  /// Seeds a file in the in-memory fs (issue #2265: the adopted log seam).
  Future<void> seedFile(String path, String content) =>
      _delegate.writeFile(path, content);

  Future<void> removeFile(String path) => _delegate.remove(path);

  // The noSuchMethod delegation below does not re-dispatch into the
  // delegate's real members (Object.noSuchMethod throws) — the fs reads
  // the adoption path exercises need explicit forwarders.
  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  String get cwd => _delegate.cwd;

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async => Err(ExecutionError(ExecutionErrorCode.shellUnavailable, 'fake'));

  Result<ShellExecResult, ExecutionError>? execResult;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async =>
      execResult ??
      Err(ExecutionError(ExecutionErrorCode.shellUnavailable, 'fake'));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      _delegate.noSuchMethod(invocation);
}

ShellJobRegistry _registry({
  void Function(ShellJobEntry)? onStart,
  void Function(ShellJobEntry)? onSettled,
  void Function(List<ShellJobEntry> adopted, {required String source})? onAdopt,
  void Function(ShellJobEntry job, Duration elapsed)? onAdoptedLiveness,
  int adoptedLivenessNoticeMinutes = 0,
  Future<ShellLivenessTable?> Function()? livenessTableOverride,
  Future<List<ShellSurvivor>?> Function(int pid)? stopAdoptedOverride,
  _FakeBackgroundEnv? env,
}) => ShellJobRegistry(
  env: env ?? _FakeBackgroundEnv(),
  onStart: onStart,
  onSettled: onSettled,
  onAdopt: onAdopt,
  onAdoptedLiveness: onAdoptedLiveness,
  adoptedLivenessNoticeMinutes: adoptedLivenessNoticeMinutes,
  livenessTableOverride: livenessTableOverride,
  stopAdoptedOverride: stopAdoptedOverride,
);

Future<String> _toolText(AgentTool tool, Map<String, dynamic> arguments) async {
  final result = await tool.execute(arguments, null, null);
  return result.content.whereType<TextContent>().map((c) => c.text).join();
}

void main() async {
  // Whether the host lets this process run `ps` (hardened/sandboxed test
  // hosts deny it — the scan then honestly finds nothing; CI Linux runs
  // the real detection paths).
  final psAvailable = await Process.run('ps', [
    '-ax',
    '-o',
    'pid=',
  ]).then((p) => p.exitCode == 0).catchError((Object _) => false);

  group('classifyShellSurvivors (pure)', () {
    // Real ps lstart strings (the classifier parses them for the window
    // check): 10:00 is old, 11:00 is in-window relative to a 10:59 spawn.
    final old = _lstartOf(DateTime(2026, 11, 16, 10, 0, 0));
    final fresh = _lstartOf(DateTime(2026, 11, 16, 11, 0, 0));
    final spawn = DateTime(2026, 11, 16, 10, 59, 0);

    test(
      'ownGroup host: the authoritative group scan catches group members',
      () {
        final survivors = classifyShellSurvivors(
          childPid: 100,
          ownGroup: true,
          ourPgid: null,
          execStart: null,
          table: [
            (pid: 100, ppid: 1, pgid: 100, lstart: old, command: 'sh -c cmd'),
            (pid: 200, ppid: 1, pgid: 100, lstart: old, command: 'sleep 300'),
            (pid: 300, ppid: 1, pgid: 999, lstart: old, command: 'escaped'),
          ],
        );
        final pids = survivors.map((s) => s.pid).toSet();
        expect(pids, {200}, reason: 'child excluded; 300 left the group');
        expect(survivors.single.command, 'sleep 300');
      },
    );

    test('non-ownGroup host: the bounded, marker-gated orphan window '
        '(macOS shape)', () {
      final marker = shellCommandOwnerMarker(50);
      expect(marker, 'fa_sh_cmd_50_');
      final wrapper = 'sh -c . \$1 sh /T/${marker}AbC/cmd.sh';
      final survivors = classifyShellSurvivors(
        childPid: 100,
        ownGroup: false,
        ourPgid: 50,
        execStart: spawn,
        execEnd: spawn.add(const Duration(minutes: 2)),
        ownerMarker: marker,
        table: [
          // The instant-& catch: orphaned, in our group, started in-window
          // AND still carrying this harness's wrapper argv.
          (pid: 600, ppid: 1, pgid: 50, lstart: fresh, command: wrapper),
          // Pre-window kin: in our group, orphaned — but it spawned long
          // before this call: not this call's survivor.
          (pid: 700, ppid: 1, pgid: 50, lstart: old, command: wrapper),
          // Still parented by a live process outside the dead subtree and
          // wearing no tag of ours — not ours (gh-2413: the chain is the
          // proof, and this one leads away from us).
          (pid: 800, ppid: 42, pgid: 50, lstart: fresh, command: 'x'),
          // Escaped our group entirely (its own setsid): the documented
          // residual gap — invisible.
          (pid: 900, ppid: 1, pgid: 999, lstart: fresh, command: wrapper),
          // The direct child: never named a survivor of itself.
          (pid: 100, ppid: 1, pgid: 50, lstart: fresh, command: wrapper),
        ],
      );
      expect(survivors.map((s) => s.pid), {600});
      expect(survivors.single.command, wrapper);
    });

    test('gh-2413 (a): a peer session\'s orphan in the shared pgid is never '
        'adopted — only a row carrying THIS harness\'s marker is', () {
      final survivors = classifyShellSurvivors(
        childPid: 100,
        ownGroup: false,
        ourPgid: 50,
        execStart: spawn,
        execEnd: spawn.add(const Duration(minutes: 2)),
        ownerMarker: shellCommandOwnerMarker(50),
        table: [
          // The reported incident: a hook backstop another session
          // launched, orphaned inside our call's window, in OUR group.
          (
            pid: 600,
            ppid: 1,
            pgid: 50,
            lstart: fresh,
            command: 'dispatch_and_watch.sh --dw-orphan-backstop x.yml',
          ),
          // A detached program this call itself launched: its own argv,
          // no marker — unprovable on this host, left alone.
          (pid: 610, ppid: 1, pgid: 50, lstart: fresh, command: 'sleep 9'),
          // A PEER harness's wrapper (its pid in the tag): foreign.
          (
            pid: 620,
            ppid: 1,
            pgid: 50,
            lstart: fresh,
            command: 'sh -c . \$1 sh /T/fa_sh_cmd_51_Zz/cmd.sh',
          ),
          // Ours: a backgrounded subshell still wearing our wrapper…
          (
            pid: 630,
            ppid: 1,
            pgid: 50,
            lstart: fresh,
            command: 'sh -c . \$1 sh /T/fa_sh_cmd_50_Ab/cmd.sh',
          ),
          // …and the work under it: its own argv, no tag — ours because
          // the ppid chain (631 → 630) reaches our wrapper.
          (pid: 631, ppid: 630, pgid: 50, lstart: fresh, command: 'sleep 9'),
          // The same shape under the PEER's wrapper (621 → 620): foreign.
          (pid: 621, ppid: 620, pgid: 50, lstart: fresh, command: 'sleep 9'),
        ],
      );
      expect(survivors.map((s) => s.pid), {630, 631});
    });

    test('gh-2413: the ancestry walk stops at init, at a missing row, and at '
        'a table cycle', () {
      const marker = 'fa_sh_cmd_50_';
      final tagged = (
        pid: 10,
        ppid: 1,
        pgid: 50,
        lstart: fresh,
        command: 'sh -c . \$1 sh /T/fa_sh_cmd_50_Ab/cmd.sh',
      );
      final orphan = (
        pid: 11,
        ppid: 1,
        pgid: 50,
        lstart: fresh,
        command: 'sleep 9',
      );
      final byPid = {tagged.pid: tagged};
      expect(ownedByMarker(tagged, byPid, marker), isTrue);
      // Chain to init without a tag.
      expect(ownedByMarker(orphan, byPid, marker), isFalse);
      // Parent missing from the table.
      final stray = (
        pid: 12,
        ppid: 99,
        pgid: 50,
        lstart: fresh,
        command: 'sleep 9',
      );
      expect(ownedByMarker(stray, byPid, marker), isFalse);
      // A cycle (a recycled pid mid-walk) terminates — false, never hangs.
      final cyc = <int, ProcessDetailRow>{
        20: (pid: 20, ppid: 21, pgid: 50, lstart: fresh, command: 'a'),
        21: (pid: 21, ppid: 20, pgid: 50, lstart: fresh, command: 'b'),
      };
      expect(ownedByMarker(cyc[20]!, cyc, marker), isFalse);
      // A grandchild two levels under the tag.
      final tree = {
        ...byPid,
        orphan.pid: orphan,
        stray.pid: (pid: 12, ppid: 10, pgid: 50, lstart: fresh, command: 'c'),
        13: (pid: 13, ppid: 12, pgid: 50, lstart: fresh, command: 'd'),
      };
      expect(ownedByMarker(tree[12]!, tree, marker), isTrue);
      expect(ownedByMarker(tree[13]!, tree, marker), isTrue);
    });

    test('gh-2413 (a): the upper bound — a process started after the call '
        'ended is never its survivor', () {
      final marker = shellCommandOwnerMarker(50);
      final inWindow = _lstartOf(DateTime(2026, 11, 16, 10, 59, 20));
      final after = _lstartOf(DateTime(2026, 11, 16, 11, 0, 30));
      final wrapper = 'sh -c . \$1 sh /T/${marker}Ab/cmd.sh';
      final survivors = classifyShellSurvivors(
        childPid: 100,
        ownGroup: false,
        ourPgid: 50,
        execStart: spawn,
        execEnd: DateTime(2026, 11, 16, 11, 0, 0),
        ownerMarker: marker,
        table: [
          (pid: 600, ppid: 1, pgid: 50, lstart: inWindow, command: wrapper),
          (pid: 601, ppid: 1, pgid: 50, lstart: after, command: wrapper),
        ],
      );
      expect(survivors.map((s) => s.pid), {600});
      // Without a bound the later orphan would have been adopted too.
      expect(
        classifyShellSurvivors(
          childPid: 100,
          ownGroup: false,
          ourPgid: 50,
          execStart: spawn,
          ownerMarker: marker,
          table: [
            (pid: 601, ppid: 1, pgid: 50, lstart: after, command: wrapper),
          ],
        ).map((s) => s.pid),
        {601},
        reason: 'execEnd stays optional for ownGroup-style callers',
      );
    });

    test('gh-2413: no owner marker (harness pid unknown) adopts nothing '
        'on the window alone; the ownGroup scan needs no marker', () {
      final row = (
        pid: 600,
        ppid: 1,
        pgid: 50,
        lstart: fresh,
        command: 'sh -c . \$1 sh /T/fa_sh_cmd_50_Ab/cmd.sh',
      );
      expect(
        classifyShellSurvivors(
          childPid: 100,
          ownGroup: false,
          ourPgid: 50,
          execStart: spawn,
          table: [row],
        ),
        isEmpty,
      );
      // The authoritative ownGroup scan is unaffected by the marker rule.
      expect(
        classifyShellSurvivors(
          childPid: 100,
          ownGroup: true,
          ourPgid: 50,
          execStart: spawn,
          table: [
            (pid: 600, ppid: 1, pgid: 100, lstart: fresh, command: 'sleep 9'),
          ],
        ).map((s) => s.pid),
        {600},
      );
    });

    test('a missing or unparseable table adopts nothing (AC7 shape)', () {
      expect(
        classifyShellSurvivors(
          childPid: 100,
          ownGroup: true,
          ourPgid: null,
          execStart: null,
          table: null,
        ),
        isEmpty,
      );
      expect(
        classifyShellSurvivors(
          childPid: 100,
          ownGroup: false,
          ourPgid: 100,
          execStart: DateTime.now(),
          table: null,
        ),
        isEmpty,
      );
    });
  });

  group('registry adoption (fake probe/kill seams)', () {
    test(
      'adoptSurvivors creates liveness-only entries, fires callbacks',
      () async {
        final started = <ShellJobEntry>[];
        final adoptBatches = <List<ShellJobEntry>>[];
        final registry = _registry(
          onStart: started.add,
          onAdopt: (adopted, {required source}) => adoptBatches.add(adopted),
        );
        final adopted = await registry.adoptSurvivors('nohup x &', const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'sleep 300'),
        ]);
        expect(adopted, hasLength(1));
        final entry = adopted.single;
        expect(entry.isAdopted, isTrue);
        expect(entry.isRunning, isTrue);
        expect(entry.pid, 42);
        expect(
          entry.exitCode,
          isNull,
          reason: 'not our child — never fabricated',
        );
        expect(entry.command, 'sleep 300');
        expect(entry.logPath, isEmpty, reason: 'no captured log by design');
        expect(started, [entry]);
        expect(adoptBatches.single.single, same(entry));
      },
    );

    test(
      'notify: false skips the adoption callback (tool reports inline)',
      () async {
        var adoptCalls = 0;
        final registry = _registry(
          onAdopt: (_, {required source}) => adoptCalls++,
        );
        await registry.adoptSurvivors('cmd', const [
          ShellSurvivor(pid: 7, startTag: 'S'),
        ], notify: false);
        expect(adoptCalls, 0);
      },
    );

    test(
      'foreground timeout error survivors are adopted before the throw',
      () async {
        final env = _FakeBackgroundEnv();
        env.execResult = Err(
          ExecutionError(
            ExecutionErrorCode.timeout,
            'timeout: 0:00:01.000000',
            survivors: const [
              ShellSurvivor(pid: 42, startTag: 'S1', command: 'sleep 300'),
            ],
          ),
        );
        final registry = ShellJobRegistry(
          env: env,
          livenessTableOverride: () async => null,
          stopAdoptedOverride: (_) async => const [],
        );
        final tool = shellTool(
          env,
          jobs: registry,
          autoBackgroundAfter: Duration.zero,
        );

        Object? failure;
        try {
          await tool.execute({'command': 'make'}, null, null);
        } on Object catch (error) {
          failure = error;
        }
        expect(failure, isA<StateError>());
        expect(failure.toString(), contains('Command timed out'));
        expect(failure.toString(), contains('adopted as tracked jobs'));
        expect(registry.jobs, hasLength(1));
        expect(registry.jobs.single.isAdopted, isTrue);
        expect(registry.jobs.single.pid, 42);
        await registry.jobs.single.stop();
      },
    );

    test(
      'a pid already tracked by a running job is never double-adopted',
      () async {
        final registry = _registry();
        final survivor = const [ShellSurvivor(pid: 42, startTag: 'S')];
        expect(await registry.adoptSurvivors('cmd', survivor), hasLength(1));
        expect(await registry.adoptSurvivors('cmd', survivor), isEmpty);
      },
    );

    test(
      'poll observes death: settled fires, no exit code, no stopReason',
      () async {
        var table = (pids: {42}, starts: {42: 'S1'});
        final settled = <ShellJobEntry>[];
        final registry = _registry(
          onSettled: settled.add,
          livenessTableOverride: () async => table,
        );
        final entry = (await registry.adoptSurvivors('cmd', const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
        ])).single;
        await registry.adoptedPollTickForTest();
        await pumpEventQueue();
        expect(
          entry.isRunning,
          isTrue,
          reason: 'alive pid with matching start',
        );
        // The process dies: the next sample misses the pid.
        table = (pids: <int>{}, starts: <int, String>{});
        await registry.adoptedPollTickForTest();
        expect(entry.isRunning, isFalse);
        expect(entry.exitCode, isNull, reason: 'liveness-only');
        expect(entry.stopReason, isNull, reason: 'a natural death, not a stop');
        await pumpEventQueue();
        expect(entry.settledAt, isNotNull);
        expect(settled, contains(entry));
      },
    );

    test(
      'recycled pid (start drift) reads as exited — never as another',
      () async {
        var table = (pids: {42}, starts: {42: 'S1'});
        final registry = _registry(livenessTableOverride: () async => table);
        final entry = (await registry.adoptSurvivors('cmd', const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
        ])).single;
        table = (pids: {42}, starts: {42: 'RECYCLED'});
        await registry.adoptedPollTickForTest();
        expect(entry.isRunning, isFalse);
      },
    );

    test(
      'a probe-less poll sample keeps the entry running (#478 rule)',
      () async {
        ({Set<int> pids, Map<int, String> starts})? table = (
          pids: {42},
          starts: {42: 'S1'},
        );
        final registry = _registry(livenessTableOverride: () async => table);
        final entry = (await registry.adoptSurvivors('cmd', const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
        ])).single;
        table = null;
        await registry.adoptedPollTickForTest();
        expect(entry.isRunning, isTrue);
      },
    );

    test('stop kills through the seam and settles honestly', () async {
      final killed = <int>[];
      final settled = <ShellJobEntry>[];
      final registry = _registry(
        onSettled: settled.add,
        livenessTableOverride: () async => (pids: {42}, starts: {42: 'S1'}),
        stopAdoptedOverride: (pid) async {
          killed.add(pid);
          return const [];
        },
      );
      final entry = (await registry.adoptSurvivors('cmd', const [
        ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
      ])).single;
      await entry.stop();
      await pumpEventQueue();
      expect(killed, [42]);
      expect(entry.isRunning, isFalse);
      expect(entry.stopReason, 'stopped');
      expect(entry.exitCode, isNull);
      expect(settled, contains(entry));
    });

    test(
      'stop surfaces the group residue on the entry (issue #2260)',
      () async {
        final registry = _registry(
          livenessTableOverride: () async => (pids: {42}, starts: {42: 'S1'}),
          stopAdoptedOverride: (pid) async => [
            ShellSurvivor(pid: 7, startTag: 'S7', command: 'tee /tmp/b.log'),
          ],
        );
        final entry = (await registry.adoptSurvivors('cmd', const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
        ])).single;
        await entry.stop();
        expect(entry.stopAttempted, isTrue);
        expect(entry.stopSurvivors, hasLength(1));
        expect(entry.stopSurvivors!.single.pid, 7);
        expect(entry.stopSurvivors!.single.startTag, 'S7');
      },
    );

    test(
      'a natural death reports no stop and no residue (issue #2260)',
      () async {
        ({Set<int> pids, Map<int, String> starts})? table = (
          pids: {42},
          starts: {42: 'S1'},
        );
        final registry = _registry(livenessTableOverride: () async => table);
        final entry = (await registry.adoptSurvivors('cmd', const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
        ])).single;
        table = (pids: <int>{}, starts: <int, String>{});
        await registry.adoptedPollTickForTest();
        expect(entry.isRunning, isFalse);
        expect(entry.stopAttempted, isFalse);
        expect(entry.stopSurvivors, isNull);
        expect(adoptedStopKeepsManifestRecord(entry), isFalse);
      },
    );

    test('the manifest-keep predicate answers the stop residue tri-state '
        '(issue #2260)', () async {
      Future<ShellJobEntry> entryWithResidue(
        List<ShellSurvivor>? residue,
      ) async {
        final registry = _registry(
          livenessTableOverride: () async => (pids: {42}, starts: {42: 'S1'}),
          stopAdoptedOverride: (pid) async => residue,
        );
        final entry = (await registry.adoptSurvivors('cmd', const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
        ])).single;
        await entry.stop();
        return entry;
      }

      // Verified-gone stop: the manifest record is dropped as before.
      expect(
        adoptedStopKeepsManifestRecord(await entryWithResidue(const [])),
        isFalse,
      );
      // Unverified group / survivors: the record is KEPT — the boot
      // sweep's only path back to the orphaned group (AC2).
      expect(
        adoptedStopKeepsManifestRecord(await entryWithResidue(null)),
        isTrue,
      );
      expect(
        adoptedStopKeepsManifestRecord(
          await entryWithResidue(const [ShellSurvivor(pid: 7, startTag: 'S7')]),
        ),
        isTrue,
      );
    });

    test('adoptRunningEntry keeps the manifest identity (AC5)', () async {
      final registry = _registry();
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final entry = registry.adoptRunningEntry(
        id: 'sh-9-prev',
        command: 'watch.sh',
        pid: 4242,
        pidStart: 'PS',
        startedAtMs: now.millisecondsSinceEpoch,
      );
      expect(entry.id, 'sh-9-prev');
      expect(entry.isAdopted, isTrue);
      expect(entry.startedAt, now);
      expect(entry.isRunning, isTrue);
    });

    test(
      'liveness reminder cadence (AC4): once per window, never at 0',
      () async {
        final table = (pids: {42}, starts: {42: 'S1'});
        final reminded = <String>[];
        final registry = _registry(
          adoptedLivenessNoticeMinutes: 5,
          onAdoptedLiveness: (job, elapsed) => reminded.add(job.id),
          livenessTableOverride: () async => table,
        );
        registry.adoptRunningEntry(
          id: 'sh-1-x',
          command: 'x',
          pid: 42,
          pidStart: 'S1',
          startedAtMs: DateTime.now()
              .subtract(const Duration(minutes: 6))
              .millisecondsSinceEpoch,
        );
        await registry.adoptedPollTickForTest();
        expect(reminded, [
          'sh-1-x',
        ], reason: '6 min elapsed ≥ the 5 min window');
        await registry.adoptedPollTickForTest();
        expect(reminded, hasLength(1), reason: 'inside the restarted window');

        // Default cadence 0: no reminders ever.
        final quiet = _registry(
          onAdoptedLiveness: (job, elapsed) => reminded.add(job.id),
          livenessTableOverride: () async => table,
        );
        quiet.adoptRunningEntry(
          id: 'sh-2-y',
          command: 'y',
          pid: 42,
          pidStart: 'S1',
          startedAtMs: DateTime.now()
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
        );
        await quiet.adoptedPollTickForTest();
        expect(reminded, hasLength(1));
      },
    );

    test('adoptedLivenessDue (pure): 0 disables; base is last notice', () {
      final now = DateTime.now();
      expect(
        adoptedLivenessDue(
          now: now,
          startedAt: now.subtract(const Duration(hours: 1)),
          noticeMinutes: 0,
        ),
        isFalse,
      );
      final start = now.subtract(const Duration(minutes: 11));
      expect(
        adoptedLivenessDue(now: now, startedAt: start, noticeMinutes: 10),
        isTrue,
      );
      expect(
        adoptedLivenessDue(
          now: now,
          startedAt: start,
          lastNoticeAt: now.subtract(const Duration(minutes: 2)),
          noticeMinutes: 10,
        ),
        isFalse,
        reason: 'the window restarts at the last fired notice',
      );
    });
  });

  group('bash_job tool over adopted entries (driven through the tool)', () {
    test('status names the adopted marker and the missing log (AC2)', () async {
      final registry = _registry();
      final entry = (await registry.adoptSurvivors('nohup x &', const [
        ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
      ])).single;
      final text = await _toolText(bashJobTool(registry), {
        'action': 'status',
        'id': entry.id,
      });
      expect(text, contains('running (adopted pid 99)'));
      expect(text, contains('no captured log'));
    });

    test(
      'output renders the adopted explanation, never an empty log (AC3)',
      () async {
        final registry = _registry();
        final entry = (await registry.adoptSurvivors('nohup x &', const [
          ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
        ])).single;
        final text = await _toolText(bashJobTool(registry), {
          'action': 'output',
          'id': entry.id,
        });
        expect(text, contains('ADOPTED background process'));
        expect(text, contains('nohup.out'));
        expect(text, contains('Still running'));
        expect(text, contains('pid 99'));
      },
    );

    test(
      'stop of a dead adopted job reports no fabricated exit code',
      () async {
        var table = (pids: {99}, starts: {99: 'S'});
        final registry = _registry(livenessTableOverride: () async => table);
        final entry = (await registry.adoptSurvivors('nohup x &', const [
          ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
        ])).single;
        table = (pids: <int>{}, starts: <int, String>{});
        await registry.adoptedPollTickForTest();
        expect(entry.isRunning, isFalse);
        final text = await _toolText(bashJobTool(registry), {
          'action': 'stop',
          'id': entry.id,
        });
        expect(text, contains('no exit code'));
      },
    );

    test('stop kills a live adopted job (AC2)', () async {
      final killed = <int>[];
      final registry = _registry(
        livenessTableOverride: () async => (pids: {99}, starts: {99: 'S'}),
        stopAdoptedOverride: (pid) async {
          killed.add(pid);
          return const [];
        },
      );
      final entry = (await registry.adoptSurvivors('nohup x &', const [
        ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
      ])).single;
      final text = await _toolText(bashJobTool(registry), {
        'action': 'stop',
        'id': entry.id,
      });
      expect(killed, [99]);
      expect(text, 'Stopped ${entry.id}');
    });

    test('stop with surviving group members names them, never bare '
        '"Stopped" (issue #2260)', () async {
      final registry = _registry(
        livenessTableOverride: () async => (pids: {99}, starts: {99: 'S'}),
        stopAdoptedOverride: (pid) async => const [
          ShellSurvivor(pid: 7, startTag: 'S7', command: 'tee /tmp/b.log'),
          ShellSurvivor(pid: 8, startTag: 'S8'),
        ],
      );
      final entry = (await registry.adoptSurvivors('nohup x &', const [
        ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
      ])).single;
      final text = await _toolText(bashJobTool(registry), {
        'action': 'stop',
        'id': entry.id,
      });
      expect(text, contains('Stopped the leader ${entry.id}'));
      expect(text, isNot(contains('Stopped ${entry.id}')));
      expect(text, contains('2 process group member(s) still running'));
      expect(text, contains(': pid 7, pid 8.'));
      expect(text, contains('the next boot reaps the survivors'));
    });

    test('stop on an unverifiable group admits it instead of bare '
        '"Stopped" (issue #2260 AC2)', () async {
      final registry = _registry(
        livenessTableOverride: () async => (pids: {99}, starts: {99: 'S'}),
        stopAdoptedOverride: (pid) async => null,
      );
      final entry = (await registry.adoptSurvivors('nohup x &', const [
        ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
      ])).single;
      final text = await _toolText(bashJobTool(registry), {
        'action': 'stop',
        'id': entry.id,
      });
      expect(text, isNot(contains('Stopped ${entry.id}')));
      expect(text, contains('group members may remain'));
      expect(text, contains('the next boot reaps any survivors'));
    });

    test('a leader that survived the kill rounds is never claimed stopped '
        '(issue #2260 review)', () async {
      final registry = _registry(
        livenessTableOverride: () async => (pids: {99}, starts: {99: 'S'}),
        stopAdoptedOverride: (pid) async => const [
          // The leader pid itself, plus one member: D-state/EPERM shape.
          ShellSurvivor(pid: 99, startTag: 'S', command: 'make test'),
          ShellSurvivor(pid: 7, startTag: 'S7'),
        ],
      );
      final entry = (await registry.adoptSurvivors('nohup x &', const [
        ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
      ])).single;
      final text = await _toolText(bashJobTool(registry), {
        'action': 'stop',
        'id': entry.id,
      });
      expect(text, contains('still running (pid 99)'));
      expect(text, isNot(contains('Stopped')));
      expect(text, isNot(contains('next boot reaps')));
      expect(text, contains('pid 7'));
      expect(text, contains('manual cleanup'));
    });

    test('stop refuses a recycled pid and marks the entry gone (r3)', () async {
      final killed = <int>[];
      ({Set<int> pids, Map<int, String> starts})? table = (
        pids: {99},
        starts: {99: 'S'},
      );
      final registry = _registry(
        livenessTableOverride: () async => table,
        stopAdoptedOverride: (pid) async {
          killed.add(pid);
          return const [];
        },
      );
      final entry = (await registry.adoptSurvivors('nohup x &', const [
        ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
      ])).single;
      // The pid was recycled onto a stranger: different start string.
      table = (pids: {99}, starts: {99: 'OTHER'});
      final text = await _toolText(bashJobTool(registry), {
        'action': 'stop',
        'id': entry.id,
      });
      expect(killed, isEmpty, reason: 'never signal an unverified pid');
      expect(entry.isRunning, isFalse);
      expect(text, contains('no exit code'));
    });

    test('stop refuses a pid missing from the fresh table (r3)', () async {
      final killed = <int>[];
      ({Set<int> pids, Map<int, String> starts})? table = (
        pids: {99},
        starts: {99: 'S'},
      );
      final registry = _registry(
        livenessTableOverride: () async => table,
        stopAdoptedOverride: (pid) async {
          killed.add(pid);
          return const [];
        },
      );
      final entry = (await registry.adoptSurvivors('nohup x &', const [
        ShellSurvivor(pid: 99, startTag: 'S', command: 'sleep 300'),
      ])).single;
      table = (pids: <int>{}, starts: <int, String>{});
      await _toolText(bashJobTool(registry), {
        'action': 'stop',
        'id': entry.id,
      });
      expect(killed, isEmpty, reason: 'the process is already gone');
      expect(entry.isRunning, isFalse);
    });

    test('gh-2413: stop refuses a pid whose start tag was never recorded while '
        'the platform reports one — nothing is signaled, the job stays '
        'tracked, the tool says so', () async {
      final killed = <int>[];
      final registry = _registry(
        livenessTableOverride: () async =>
            (pids: {99}, starts: {99: 'Mon Nov 16 10:00:00 2026'}),
        stopAdoptedOverride: (pid) async {
          killed.add(pid);
          return const [];
        },
      );
      // A legacy manifest record adopted without a pidStart (the probe
      // could not report one at record time): `startTag: ''`.
      final entry = registry.adoptRunningEntry(
        id: 'sh-legacy',
        command: 'old daemon',
        pid: 99,
        adoptedFrom: 'unknown owner',
      );
      final text = await _toolText(bashJobTool(registry), {
        'action': 'stop',
        'id': entry.id,
      });
      expect(killed, isEmpty, reason: 'a recycled pid is never signaled');
      expect(entry.isRunning, isTrue);
      expect(entry.stopAttempted, isFalse);
      expect(entry.stopRefused, isTrue);
      expect(text, contains('NOT stopped: its pid 99 cannot be verified'));
      expect(text, isNot(contains('Stopped')));
    });

    test('gh-2413: a presence-only row (no start time either side) keeps the '
        'legacy kill — nothing contradicts the recorded identity', () async {
      final killed = <int>[];
      final registry = _registry(
        livenessTableOverride: () async =>
            (pids: {99}, starts: <int, String>{}),
        stopAdoptedOverride: (pid) async {
          killed.add(pid);
          return const [];
        },
      );
      final entry = registry.adoptRunningEntry(
        id: 'sh-legacy',
        command: 'old daemon',
        pid: 99,
      );
      await entry.stop();
      expect(killed, [99]);
      expect(entry.stopRefused, isFalse);
    });

    test('adoptRunningEntry is idempotent across boots (r3)', () async {
      var starts = 0;
      final registry = _registry(onStart: (_) => starts++);
      final first = registry.adoptRunningEntry(
        id: 'sh-9-prev',
        command: 'watch.sh',
        pid: 4242,
        pidStart: 'PS',
      );
      final second = registry.adoptRunningEntry(
        id: 'sh-9-prev',
        command: 'watch.sh',
        pid: 4242,
        pidStart: 'PS',
      );
      expect(identical(first, second), isTrue);
      expect(registry.jobs.where((e) => e.id == 'sh-9-prev'), hasLength(1));
      expect(starts, 1, reason: 'no double onStart, no double settle path');
    });
  });

  group('boot re-adoption resolves the native log (issue #2265)', () {
    const logDir = '/w/.fah/bash_jobs';
    const logPath = '$logDir/sh-9-prev.log';

    Future<(ShellJobRegistry, _FakeBackgroundEnv)> seededRegistry(
      String? content, {
      Future<ShellLivenessTable?> Function()? table,
    }) async {
      final env = _FakeBackgroundEnv();
      if (content != null) await env.seedFile(logPath, content);
      final registry = _registry(
        env: env,
        livenessTableOverride:
            table ?? (() async => (pids: {4242}, starts: {4242: 'PS'})),
      );
      // The boot path snapshots the job-log dir before re-adoption
      // (issue #2265); the tests ride the same real listing.
      await registry.refreshExistingJobLogIds();
      return (registry, env);
    }

    ShellJobEntry adoptAt(ShellJobRegistry registry) =>
        registry.adoptRunningEntry(
          id: 'sh-9-prev',
          command: 'watch.sh',
          pid: 4242,
          pidStart: 'PS',
        );

    test('bash_job output tails the original harness log — no apology '
        '(AC1)', () async {
      final (registry, _) = await seededRegistry('alpha\nbeta\ngamma\n');
      final entry = adoptAt(registry);
      expect(entry.logPath, logPath);
      final text = await _toolText(bashJobTool(registry), {
        'action': 'output',
        'id': 'sh-9-prev',
      });
      expect(text, contains('alpha'));
      expect(text, contains('gamma'));
      expect(text, contains('Tail of $logPath'));
      expect(text, contains('no exit code'));
      expect(
        text,
        isNot(contains('ADOPTED background process — the harness')),
        reason: 'the apology is foreign-only now',
      );
    });

    test(
      'a huge original log keeps the native tail cap (AC1 border)',
      () async {
        final lines = [for (var i = 1; i <= 120; i++) 'l$i'];
        final (registry, _) = await seededRegistry('${lines.join('\n')}\n');
        adoptAt(registry);
        final text = await _toolText(bashJobTool(registry), {
          'action': 'output',
          'id': 'sh-9-prev',
        });
        expect(text, contains('l120'), reason: 'the newest line survives');
        expect(text, isNot(contains('l70')), reason: 'only the last 50 tail');
      },
    );

    test('native-adopted settle notice names the log; the re-run advice '
        'is foreign-only (AC2)', () async {
      final (registry, _) = await seededRegistry(
        'result: ok\n',
        table: () async => (pids: <int>{}, starts: <int, String>{}),
      );
      final entry = adoptAt(registry);
      await registry.adoptedPollTickForTest();
      expect(entry.isRunning, isFalse);
      final text = adoptedJobSettleNoticeText(entry);
      expect(text, contains('Log: $logPath'));
      expect(text, contains('no exit code'));
      expect(text, isNot(contains('re-run the work')));
      expect(text, isNot(contains('nohup.out')));
    });

    test('truly foreign adoption (no log on disk) keeps today\'s texts '
        '(AC4 REG)', () async {
      final (registry, _) = await seededRegistry(null);
      final entry = adoptAt(registry);
      expect(entry.logPath, '');
      final output = await _toolText(bashJobTool(registry), {
        'action': 'output',
        'id': 'sh-9-prev',
      });
      expect(output, contains('ADOPTED background process'));
      expect(output, contains('nohup.out'));
      expect(output, isNot(contains('Tail of')));
      final notice = adoptedJobSettleNoticeText(entry);
      expect(notice, contains('re-run the work with background: true'));
      expect(notice, contains('nohup.out'));
      final status = await _toolText(bashJobTool(registry), {
        'action': 'status',
        'id': 'sh-9-prev',
      });
      expect(status, contains('no captured log'));
    });

    test('a log deleted between runs falls back to the foreign text '
        '(AC4 border)', () async {
      final (registry, env) = await seededRegistry('gone soon\n');
      final entry = adoptAt(registry);
      expect(entry.logPath, logPath);
      await env.removeFile(logPath);
      final output = await _toolText(bashJobTool(registry), {
        'action': 'output',
        'id': 'sh-9-prev',
      });
      expect(output, contains('ADOPTED background process'));
    });

    test('gh-2413: a FOREIGN session\'s `<id>.log` in the shared dir is never '
        'attached to a different adopted id (negative)', () async {
      // Another session's native job log sits in the shared dir; this
      // boot re-adopts a different id (its own record) — the id-keyed
      // snapshot must not hand it the foreign file.
      final (registry, _) = await seededRegistry('foreign output\n');
      final own = registry.adoptRunningEntry(
        id: 'sh-7-mine',
        command: 'my daemon',
        pid: 4242,
        pidStart: 'PS',
      );
      expect(own.logPath, isEmpty, reason: 'keyed by id, never by dir');
      expect(own.command, 'my daemon');
      // The foreign log stays on disk, untouched by this boot's adoption.
      expect(
        (await _toolText(bashJobTool(registry), {
          'action': 'output',
          'id': own.id,
        })),
        contains('ADOPTED background process'),
      );
    });
  });

  group('notice texts', () {
    test(
      'adoption notice batches ONE per call with pids and the caveat',
      () async {
        final registry = _registry();
        final adopted = [
          registry.adoptRunningEntry(
            id: 'sh-1-x',
            command: 'a',
            pid: 1,
            pidStart: 'S',
          ),
          registry.adoptRunningEntry(
            id: 'sh-2-x',
            command: 'b',
            pid: 2,
            pidStart: 'S',
          ),
        ];
        final text = adoptedSurvivorsNoticeText(adopted, source: 'make all');
        // gh-2413: "orphaned … near", never "left by" — the pid set is a
        // process-table sweep, not parentage evidence.
        expect(
          text,
          contains(
            "Detected 2 orphaned processes in this session's process group "
            'near `make all`',
          ),
        );
        expect(text, isNot(contains('left by')));
        expect(text, contains('(pid 1, `a`)'));
        expect(text, contains('no captured output and no exit code'));
        expect(text, contains('nohup.out'));
      },
    );

    test('settle notice carries the adopted-from clause (gh-2413): unknown '
        'owner for a legacy record, none for an inline survivor', () async {
      final registry = _registry();
      final legacy = registry.adoptRunningEntry(
        id: 'sh-5-x',
        command: 'backtest --full',
        pid: 777,
        pidStart: 'S',
        adoptedFrom: 'unknown owner',
      );
      final own = registry.adoptRunningEntry(
        id: 'sh-6-x',
        command: 'c',
        pid: 778,
        pidStart: 'S',
        adoptedFrom: 'this session',
      );
      final inline = (await registry.adoptSurvivors('make', const [
        ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
      ])).single;
      expect(
        adoptedJobSettleNoticeText(legacy),
        contains(', adopted from unknown owner) '),
      );
      expect(
        adoptedJobSettleNoticeText(own),
        contains(', adopted from this session) '),
      );
      expect(
        adoptedJobSettleNoticeText(inline),
        isNot(contains('adopted from')),
      );
      expect(adoptedFromClause(inline), isEmpty);
    });

    test(
      'adopted settle notice names pid, honesty, and the redirect hint',
      () async {
        final registry = _registry();
        final entry = registry.adoptRunningEntry(
          id: 'sh-5-x',
          command: 'backtest --full',
          pid: 777,
          pidStart: 'S',
        );
        final text = adoptedJobSettleNoticeText(entry);
        expect(text, contains('<system-notice>'));
        expect(text, contains('pid 777'));
        expect(text, contains('no exit code'));
        expect(text, contains('nohup.out'));
      },
    );

    test('settle notice after a survivors stop names the members and the '
        'kept record (issue #2260 AC2)', () async {
      final registry = _registry(
        livenessTableOverride: () async => (pids: {42}, starts: {42: 'S1'}),
        stopAdoptedOverride: (pid) async => const [
          ShellSurvivor(pid: 7, startTag: 'S7', command: 'tee b.log'),
        ],
      );
      final entry = (await registry.adoptSurvivors('make test', const [
        ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
      ])).single;
      await entry.stop();
      final text = adoptedJobSettleNoticeText(entry);
      expect(text, contains('<system-notice>'));
      expect(text, isNot(contains('no longer running')));
      expect(text, contains('1 process group member(s) is still running'));
      expect(text, contains('pid 7 (`tee b.log`)'));
      expect(text, contains('the next boot reaps the survivors'));
      expect(text, contains('nohup.out'));
    });

    test('settle notice after an unverified-group stop admits the '
        'survivors may remain (issue #2260 AC2)', () async {
      final registry = _registry(
        livenessTableOverride: () async => (pids: {42}, starts: {42: 'S1'}),
        stopAdoptedOverride: (pid) async => null,
      );
      final entry = (await registry.adoptSurvivors('make test', const [
        ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
      ])).single;
      await entry.stop();
      final text = adoptedJobSettleNoticeText(entry);
      expect(text, isNot(contains('no longer running')));
      expect(text, contains('group members may remain'));
      expect(text, contains('the next boot reaps any survivors'));
    });

    test('settle notice for a leader that survived the kill rounds claims '
        'no stop and no boot reap (issue #2260 review)', () async {
      final registry = _registry(
        livenessTableOverride: () async => (pids: {42}, starts: {42: 'S1'}),
        stopAdoptedOverride: (pid) async => const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'make test'),
          ShellSurvivor(pid: 7, startTag: 'S7'),
        ],
      );
      final entry = (await registry.adoptSurvivors('make test', const [
        ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
      ])).single;
      await entry.stop();
      final text = adoptedJobSettleNoticeText(entry);
      expect(text, contains('could NOT be stopped'));
      expect(text, isNot(contains('was stopped')));
      expect(text, isNot(contains('no longer running')));
      expect(text, isNot(contains('the next boot reaps')));
      expect(text, contains('pid 42 (`make test`)'));
      expect(text, contains('pid 7'));
      expect(text, contains('manual cleanup'));
    });

    test('dim line: every stop-residue branch has a distinct honest shape '
        '(issue #2260 — CRAP ratchet coverage)', () async {
      Future<ShellJobEntry> entryWithResidue(
        List<ShellSurvivor>? residue,
      ) async {
        final registry = _registry(
          livenessTableOverride: () async => (pids: {42}, starts: {42: 'S1'}),
          stopAdoptedOverride: (pid) async => residue,
        );
        final entry = (await registry.adoptSurvivors('make test', const [
          ShellSurvivor(pid: 42, startTag: 'S1', command: 'x'),
        ])).single;
        await entry.stop();
        return entry;
      }

      // Natural death — the plain liveness-only line.
      final plainRegistry = _registry();
      final plain = plainRegistry.adoptRunningEntry(
        id: 'sh-7-plain',
        command: 'watch.sh',
        pid: 5,
        pidStart: 'S',
      );
      expect(
        adoptedJobSettleDimText(plain),
        'sh-7-plain is no longer running (adopted pid 5, liveness-only)',
      );

      // Verified-gone stop — the same plain line.
      expect(
        adoptedJobSettleDimText(await entryWithResidue(const [])),
        contains('no longer running'),
      );

      // Unverified group — the stop admits it.
      final unverified = await entryWithResidue(null);
      expect(
        adoptedJobSettleDimText(unverified),
        '${unverified.id} stopped (adopted pid 42) — its process group is '
        'unverified; survivors may remain',
      );

      // Survivors, leader gone — members named.
      final membersAlive = await entryWithResidue(const [
        ShellSurvivor(pid: 7, startTag: 'S7'),
        ShellSurvivor(pid: 8, startTag: 'S8'),
      ]);
      expect(
        adoptedJobSettleDimText(membersAlive),
        '${membersAlive.id} stopped (adopted pid 42) — 2 group member(s) '
        'still alive: pid 7, pid 8',
      );

      // Leader itself survived — never called stopped.
      final leaderAlive = await entryWithResidue(const [
        ShellSurvivor(pid: 42, startTag: 'S1'),
        ShellSurvivor(pid: 7, startTag: 'S7'),
      ]);
      expect(
        adoptedJobSettleDimText(leaderAlive),
        '${leaderAlive.id} NOT stopped — pid 42 survived the kill signals; '
        'group member(s) still alive: pid 42, pid 7',
      );
    });

    test('liveness reminder names the elapsed minutes (AC4)', () async {
      final registry = _registry();
      final entry = registry.adoptRunningEntry(
        id: 'sh-3-x',
        command: 'watch.sh',
        pid: 5,
        pidStart: 'S',
      );
      expect(
        adoptedLivenessNoticeText(entry, const Duration(minutes: 5)),
        contains('still running after 5 min'),
      );
    });
  });

  group('bash tool description gate (AC8)', () {
    test('no jobs capability → no adoption sentence (web/mobile shape)', () {
      final tool = shellTool(MemoryExecutionEnv(cwd: '/w'), jobs: null);
      expect(tool.description.contains('survivor of a call'), isFalse);
    });

    test('jobs capability live → the adoption sentence teaches the model', () {
      final tool = shellTool(_FakeBackgroundEnv(), jobs: _registry());
      expect(tool.description, contains('survivor of a call'));
      expect(tool.description, contains('no captured output or exit code'));
    });
  });

  group('real-process detection (POSIX; AC1/AC7)', () {
    final posix = !Platform.isWindows;
    // gh-2413: on hosts without setsid (macOS) the orphan window is
    // marker-gated — a detached program's own argv cannot be proven ours,
    // so `nohup prog &` is NOT adopted there; only ownGroup hosts (Linux
    // CI: the authoritative group scan) adopt it. Both shapes are pinned.
    final ownGroup = LocalShell.ownProcessGroupAvailable;
    final needsPs = posix && psAvailable ? null : 'needs POSIX with ps access';

    // The marker must stay a valid `sleep` argument on every host: BSD
    // sleep rejects values above INT32_MAX (`usage: sleep …`, exit 1), and
    // an overflowing marker made the "orphan" die before the scan — the
    // pre-gh-2413 flake of this group on macOS. 8 digits ≈ 2.2e8 s.
    String marker() => '2201${DateTime.now().microsecondsSinceEpoch % 100000}';

    test(
      'exec adopts a nohup survivor of a normal exit on ownGroup hosts and '
      'never a detached program on marker-gated hosts (AC1 / gh-2413)',
      skip: needsPs,
      () async {
        final shell = LocalShell();
        final m = marker();
        final result = await shell.exec(
          'nohup sleep $m >/dev/null 2>&1 & echo hi',
          options: ShellExecOptions(cwd: Directory.systemTemp.path),
        );
        addTearDown(() => Process.run('pkill', ['-f', 'sleep $m']));
        expect(result.isOk, isTrue);
        final execResult = result.valueOrNull!;
        expect(execResult.exitCode, 0);
        if (ownGroup) {
          expect(execResult.survivors, hasLength(1));
          final survivor = execResult.survivors.single;
          expect(survivor.command, contains('sleep $m'));
          expect(survivor.startTag, isNotEmpty);
          Process.killPid(survivor.pid, ProcessSignal.sigkill);
        } else {
          expect(
            execResult.survivors,
            isEmpty,
            reason: 'own argv, no owner marker — unprovable, left alone',
          );
        }
      },
    );

    test(
      "gh-2413: a backgrounded SUBSHELL still wearing this harness's "
      'wrapper argv is adopted on marker-gated hosts',
      skip: !posix
          ? 'needs POSIX'
          : ownGroup
          ? 'needs a host without setsid (the marker-gated path)'
          : psAvailable
          ? null
          : 'needs ps access',
      () async {
        final shell = LocalShell();
        final m = marker();
        // Two statements on purpose: sh/bash exec-optimizes a
        // single-command subshell into the program (own argv, no marker);
        // the two-statement form keeps the wrapper argv — and the
        // `fa_sh_cmd_<pid>_` tag the classifier keys on. The `sleep` under
        // it is OURS through the ppid chain (its own argv carries nothing).
        final result = await shell.exec(
          '(nohup sleep $m >/dev/null 2>&1; :) >/dev/null 2>&1 & echo hi',
          options: ShellExecOptions(cwd: Directory.systemTemp.path),
        );
        addTearDown(() => Process.run('pkill', ['-f', 'sleep $m']));
        final execResult = result.valueOrNull!;
        expect(execResult.exitCode, 0);
        // Keyed on the work's unique marker: another test file sharing
        // this test process (same pid → same owner tag) may leave its own
        // tagged leftovers alive, and they are ours too by the rule.
        final under = execResult.survivors
            .where((s) => s.command!.contains('sleep $m'))
            .toList();
        expect(under, hasLength(1));
        final shellPid = under.single.pid - 1;
        final tagged = execResult.survivors
            .where(
              (s) =>
                  s.pid == shellPid &&
                  s.command!.contains(shellCommandOwnerMarker(pid)),
            )
            .toList();
        expect(tagged, hasLength(1));
        // Kill the work first (the subshell waits on it), then the shell.
        Process.killPid(under.single.pid, ProcessSignal.sigkill);
        Process.killPid(shellPid, ProcessSignal.sigkill);
      },
    );

    test(
      'exec adopts nothing for a clean call and a joined child (AC7)',
      skip: posix ? null : 'needs POSIX',
      () async {
        final shell = LocalShell();
        // OwnGroup hosts (setsid): the pgid contract is absolute — nothing
        // of any other call can match. Marker-gated hosts share the owner
        // tag with every other LocalShell user in this process (other test
        // files run as isolates of the same `dart test` process), so a
        // leftover THEY leave is legitimately adopted here; the contract
        // under test is that THIS call leaves nothing: no survivor may
        // reference a wrapper dir that no other call owned — a dir created
        // after the pre-call snapshot and already gone at the post-call
        // one is this call's own (its wrapper deleted it at exit).
        var knownDirs = ownGroup ? const <String>{} : _liveScriptDirs();
        String? own(Iterable<ShellSurvivor> survivors) {
          final post = _liveScriptDirs();
          for (final s in survivors) {
            final tag = _scriptDirTagOf(s.command ?? '');
            if (tag != null &&
                !knownDirs.contains(tag) &&
                !post.contains(tag)) {
              return tag;
            }
          }
          knownDirs = post;
          return null;
        }

        final clean = await shell.exec(
          'echo done',
          options: ShellExecOptions(cwd: Directory.systemTemp.path),
        );
        if (ownGroup) {
          expect(clean.valueOrNull!.survivors, isEmpty);
        } else {
          expect(
            own(clean.valueOrNull!.survivors),
            isNull,
            reason: 'a clean call left a process of its own behind',
          );
        }

        // A backgrounded child the shell WAITS on is dead at shell exit —
        // never adopted.
        final joined = await shell.exec(
          'sleep 0.3 & wait',
          options: ShellExecOptions(cwd: Directory.systemTemp.path),
        );
        if (ownGroup) {
          expect(joined.valueOrNull!.survivors, isEmpty);
        } else {
          expect(
            own(joined.valueOrNull!.survivors),
            isNull,
            reason: 'a joined child outlived its call',
          );
        }
      },
    );

    test(
      'timeout-killed calls report no survivors (the kill reaped the tree)',
      skip: posix ? null : 'needs POSIX',
      () async {
        final shell = LocalShell();
        final result = await shell.exec(
          'nohup sleep 2201999 >/dev/null 2>&1 & echo bg; sleep 30',
          options: ShellExecOptions(
            cwd: Directory.systemTemp.path,
            timeout: const Duration(milliseconds: 400),
          ),
        );
        addTearDown(() => Process.run('pkill', ['-f', 'sleep 2201999']));
        // The exec errors with the timeout verdict; survivors are never
        // reported on a killed call (gh-1053 reaped what it could reach).
        expect(result.isErr, isTrue);
        expect(result.errorOrNull!.code, ExecutionErrorCode.timeout);
      },
    );

    test(
      'registry job path: a nohup survivor of a settled job is adopted on '
      'ownGroup hosts, left alone on marker-gated hosts',
      skip: needsPs,
      () async {
        final workspace = await Directory.systemTemp.createTemp('fah2201-');
        addTearDown(() => workspace.delete(recursive: true));
        final m = marker();
        addTearDown(() => Process.run('pkill', ['-f', 'sleep $m']));
        final adoptedBatches = <List<ShellJobEntry>>[];
        final registry = ShellJobRegistry(
          env: LocalExecutionEnv(cwd: workspace.path),
          onAdopt: (adopted, {required source}) => adoptedBatches.add(adopted),
        );
        final job = await registry.start(
          'nohup sleep $m >/dev/null 2>&1 & echo started',
        );
        await job.settled;
        // The settle listener adopts the survivor the env buffered.
        await pumpEventQueue();
        final adopted = [
          for (final entry in registry.jobs)
            if (entry.isAdopted) entry,
        ];
        if (ownGroup) {
          expect(adopted, hasLength(1));
          expect(adoptedBatches, hasLength(1));
          expect(adopted.single.command, contains('sleep $m'));
          expect(adopted.single.pid, isNot(job.pid));
          // Stop the adopted process so nothing outlives the test.
          await adopted.single.stop();
        } else {
          // The detached program is unprovable here: never adopted, never
          // announced. (Leftovers of an earlier test may be adopted — this
          // call's window is theirs too — so the check keys on OUR work.)
          expect(adopted.where((e) => e.command.contains('sleep $m')), isEmpty);
          expect(
            adoptedBatches.where(
              (b) => b.any((e) => e.command.contains('sleep $m')),
            ),
            isEmpty,
          );
          for (final entry in adopted) {
            await entry.stop();
          }
        }
        await pumpEventQueue();
      },
    );

    test(
      'bash tool inline path: adoption notice rides the result (AC1)',
      skip: needsPs,
      () async {
        final workspace = await Directory.systemTemp.createTemp('fah2201t-');
        addTearDown(() => workspace.delete(recursive: true));
        final m = marker();
        addTearDown(() => Process.run('pkill', ['-f', 'sleep $m']));
        final registry = ShellJobRegistry(
          env: LocalExecutionEnv(cwd: workspace.path),
        );
        final tool = shellTool(
          LocalExecutionEnv(cwd: workspace.path),
          jobs: registry,
          // The classic foreground route: the default 60s auto-background
          // would make this call a registry job from the start, and the
          // adoption notice would ride onAdopt instead of the result.
          autoBackgroundAfter: Duration.zero,
        );
        // gh-2413: the marker-gated path needs a survivor that still wears
        // the wrapper argv (a two-statement backgrounded subshell).
        final command = ownGroup
            ? 'nohup sleep $m >/dev/null 2>&1 & echo launched'
            : '(nohup sleep $m >/dev/null 2>&1; :) >/dev/null 2>&1 '
                  '& echo launched';
        final text = await _toolText(tool, {'command': command});
        expect(text, contains('adopted as tracked jobs'));
        expect(text, contains('orphaned process'));
        expect(text, contains("in this session's process group near"));
        expect(text, isNot(contains('left by')));
        final adopted = [
          for (final entry in registry.jobs)
            if (entry.isAdopted) entry,
        ];
        // The work itself is adopted on both hosts; on the marker-gated
        // host the tagged subshell that launched it rides along (the
        // ancestry proof), so the count is 2 there.
        final work = adopted.where((e) => e.command.contains('sleep $m'));
        expect(work, hasLength(1));
        expect(text, contains(work.single.id));
        if (!ownGroup) {
          // The tagged subshell that launched the work rides along (its
          // pid is the work's fork parent) — the ancestry proof itself.
          expect(
            adopted.any(
              (e) =>
                  e.pid == work.single.pid! - 1 &&
                  e.command.contains(shellCommandOwnerMarker(pid)),
            ),
            isTrue,
          );
        }
        // Stop everything adopted (leftovers included) so nothing outlives
        // the test.
        for (final entry in adopted) {
          await entry.stop();
        }
        await pumpEventQueue();
      },
    );
  });
}

/// The `fa_sh_cmd_<pid>_XXXX` wrapper dirs alive in the system temp right
/// now — the script dirs of this process's still-running LocalShell
/// wrappers (gh-2413 owner tags). A survivor referencing a dir OUTSIDE a
/// pre-call snapshot was created by the call under test.
Set<String> _liveScriptDirs() => {
  for (final entity in Directory.systemTemp.listSync())
    if (entity is Directory)
      entity.uri.pathSegments.where((s) => s.isNotEmpty).last,
}.where((name) => name.startsWith('fa_sh_cmd_')).toSet();

final _scriptDirTagPattern = RegExp(r'fa_sh_cmd_\d+_[A-Za-z0-9]+');

/// The wrapper dir tag a survivor's command line references, if any.
String? _scriptDirTagOf(String command) =>
    _scriptDirTagPattern.firstMatch(command)?.group(0);

/// Renders a local DateTime the way `ps -o lstart=` prints it (the test
/// fixtures reuse the real format so [tryParseLstart] round-trips).
String _lstartOf(DateTime at) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${days[at.weekday - 1]} ${months[at.month - 1]} ${at.day} '
      '${two(at.hour)}:${two(at.minute)}:${two(at.second)} ${at.year}';
}
