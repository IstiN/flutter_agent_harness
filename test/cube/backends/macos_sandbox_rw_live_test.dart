/// Issue #709 E2E1: through the real kernel backend, an `rw` mount under a
/// read-denied prefix is READABLE (AC2) and still WRITABLE (AC3) — today the
/// read leg dies with `Operation not permitted` because `readWrite` emits no
/// `file-read*` allow, so the curated `(deny file-read* (subpath "/Users"))`
/// has no later rule to lose to.
///
/// Runs only where `sandbox-exec` exists AND the host can stage a fixture
/// under the read-denied `/Users` prefix without a sandbox in the way. The
/// skipped legs are named in the log, never silent — including the
/// already-sandboxed host case: nested sandbox profiles intersect, so an
/// inner allow cannot lift an outer deny (a sandboxed dev machine — e.g. an
/// fa cube session — cannot host this test; use a clean macOS runner/host).
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cube/backends/cube_backend.dart';
import 'package:flutter_agent_harness/src/cube/backends/macos_sandbox.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
import 'package:test/test.dart';

/// Whether `sandbox-exec` is available on this host.
final bool _hasSandboxExec =
    !Platform.isWindows &&
    Process.runSync('which', ['sandbox-exec']).exitCode == 0;

/// Whether the HOST itself already sandboxes reads (e.g. an fa cube
/// session): nested sandbox profiles intersect, so this test's inner
/// `allow` rules cannot lift the outer denies — the live legs can only run
/// on a clean host (CI macOS leg or a developer machine).
final bool _hostAlreadySandboxed = () {
  try {
    File('/etc/hosts').readAsStringSync();
    return false;
  } catch (_) {
    return true;
  }
}();

/// The user home, when it sits under the read-denied `/Users` prefix (the
/// only denied prefix a normal user can stage a writable fixture under).
final String? _homeUnderUsers = () {
  final home = Platform.environment['HOME'] ?? '';
  return home.startsWith('/Users/') ? home : null;
}();

/// Whether the host can stage the fixture OUTSIDE any sandbox: write then
/// read back a probe file under `/Users`. A host that is itself sandboxed
/// (an fa cube session) fails here — its outer deny cannot be lifted by the
/// test's inner profile, so the legs would be confounded, not failed.
final bool _canStage = () {
  if (_homeUnderUsers == null) return false;
  final probe = File(
    '$_homeUnderUsers/.fah-rw-live-probe-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    probe.writeAsStringSync('probe');
    final readBack = probe.readAsStringSync();
    probe.deleteSync();
    return readBack == 'probe';
  } catch (_) {
    return false;
  }
}();

void main() {
  group(
    'macOS kernel mode live: rw mount under a read-denied prefix (issue '
    '709)',
    () {
      late Directory workspace;
      late Directory rwMount;
      late File control;
      late String profilePath;

      setUp(() {
        final stamp = DateTime.now().microsecondsSinceEpoch;
        workspace = Directory.systemTemp.createTempSync('fah-cube-live-');
        rwMount = Directory('$_homeUnderUsers/fah-rw-live-$stamp')
          ..createSync(recursive: true);
        File('${rwMount.path}/seed.txt').writeAsStringSync('kernel-readable');
        // A file under /Users but OUTSIDE the mount: the curated read deny
        // must keep blocking it (the fix re-allows the mount, not /Users).
        control = File('$_homeUnderUsers/fah-rw-live-control-$stamp.txt')
          ..writeAsStringSync('no-read-here');
        final spec = CubeSpec(
          name: 'l1-dev',
          backend: CubeBackendMode.kernel,
          tools: const CubeToolPolicy(allow: {'head', 'printf'}),
          filesystem: CubeFsPolicy(
            workspace: workspace.path,
            mounts: [
              CubeMount(path: rwMount.path, access: CubePathAccess.readWrite),
            ],
          ),
        );
        profilePath = '${workspace.path}/.fah/cube-profiles/rw-live.sb';
        Directory(
          '${workspace.path}/.fah/cube-profiles',
        ).createSync(recursive: true);
        File(profilePath).writeAsStringSync(
          const MacOsSandboxBackend().buildSandboxProfile(
            spec,
            workspaceRoot: workspace.path,
          ),
        );
      });

      tearDown(() {
        workspace.deleteSync(recursive: true);
        rwMount.deleteSync(recursive: true);
        if (control.existsSync()) control.deleteSync();
      });

      Future<ProcessResult> run(String command) => Process.run('/bin/sh', [
        '-c',
        'cd ${shellQuote(workspace.path)} && '
            '${const MacOsSandboxBackend().wrapCommand(command, profilePath: profilePath)}',
      ]);

      test('AC2: a wrapped shell READS a file under the rw mount', () async {
        final result = await run(
          'head -c 15 ${shellQuote('${rwMount.path}/seed.txt')}',
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(result.stdout.toString(), contains('kernel-readable'));
      });

      test('AC3: a wrapped shell still WRITES under the rw mount', () async {
        final result = await run(
          'printf appended >> ${shellQuote('${rwMount.path}/log.txt')} && '
          'printf fresh > ${shellQuote('${rwMount.path}/new.txt')}',
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(File('${rwMount.path}/log.txt').readAsStringSync(), 'appended');
        expect(File('${rwMount.path}/new.txt').readAsStringSync(), 'fresh');
      });

      test('the /Users read deny still blocks non-mounted paths', () async {
        final result = await run('head -c 4 ${shellQuote(control.path)}');
        expect(result.exitCode, isNot(0));
        expect(result.stdout, isEmpty);
      });
    },
    skip: !_hasSandboxExec
        ? 'live macOS kernel mode: sandbox-exec not on this host'
        : _hostAlreadySandboxed
        ? 'live rw leg: host is itself sandboxed (nested sandbox profiles '
              'intersect — an inner allow cannot lift an outer deny)'
        : _homeUnderUsers == null
        ? 'live rw leg: HOME is not under the read-denied /Users prefix'
        : !_canStage
        ? 'live rw leg: host cannot stage a /Users fixture'
        : false,
  );
}
