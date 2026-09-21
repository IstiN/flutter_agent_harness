/// Issue #732 AC3, live: a nested `rw` mount survives a broader `ro`
/// mount DECLARED AFTER it — the exact uv break. sandbox-exec resolves a
/// matching conflict by the LAST matching rule, so the emitter must sort
/// broad→narrow; under the old declaration-order emission the parent's
/// deny-write was the last matching write rule and the nested child lost
/// (`Operation not permitted` on every write).
///
/// Runs only where `sandbox-exec` exists AND the host is not itself
/// sandboxed (nested sandbox profiles intersect: an inner allow cannot
/// lift an outer deny, so an fa-cube session cannot host this test). The
/// skipped legs are named in the log, never silent. The fixture lives in
/// the system temp dir — no `/Users` staging needed, the mounts are
/// workspace-internal.
///
/// ```sh
/// dart test test/cube/backends/macos_sandbox_nested_rw_live_test.dart
/// ```
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cube/backends/cube_backend.dart';
import 'package:flutter_agent_harness/src/cube/backends/macos_sandbox.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:test/test.dart';

/// Whether `sandbox-exec` is available on this host.
final bool _hasSandboxExec =
    !Platform.isWindows &&
    Process.runSync('which', ['sandbox-exec']).exitCode == 0;

/// Whether the HOST itself already sandboxes reads (e.g. an fa cube
/// session): nested sandbox profiles intersect, so this test's inner
/// `allow` rules cannot lift the outer denies — the live legs can only
/// run on a clean host (the CI macOS kernel leg or a developer machine).
final bool _hostAlreadySandboxed = () {
  try {
    File('/etc/hosts').readAsStringSync();
    return false;
  } catch (_) {
    return true;
  }
}();

void main() {
  group(
    'macOS kernel mode live: nested rw mount under a broader ro mount '
    '(issue 732)',
    () {
      late Directory workspace;
      late Directory uvMount;
      late String profilePath;

      setUp(() {
        workspace = Directory.systemTemp.createTempSync('fah-nested-rw-');
        uvMount = Directory('${workspace.path}/data/uv')
          ..createSync(recursive: true);
        File('${uvMount.path}/seed.txt').writeAsStringSync('seed-ok');
        // Child rw FIRST, broader ro parent LAST: the adversarial order
        // that used to kill the nested mount under last-match-wins.
        final spec = CubeSpec(
          name: 'nested-rw',
          backend: CubeBackendMode.kernel,
          filesystem: CubeFsPolicy(
            workspace: workspace.path,
            mounts: [
              CubeMount(path: uvMount.path, access: CubePathAccess.readWrite),
              CubeMount(path: workspace.path, access: CubePathAccess.readOnly),
            ],
          ),
        );
        profilePath = '${workspace.path}/.fah/cube-profiles/nested-rw.sb';
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
      });

      Future<ProcessResult> run(String command) => Process.run('/bin/sh', [
        '-c',
        'cd ${shellQuote(workspace.path)} && '
            '${const MacOsSandboxBackend().wrapCommand(command, profilePath: profilePath)}',
      ]);

      test('AC3: the nested rw mount READS its seed, WRITES and reads back '
          'a probe', () async {
        final result = await run(
          'head -c 7 ${shellQuote('${uvMount.path}/seed.txt')} && '
          'printf probe > ${shellQuote('${uvMount.path}/probe.txt')} && '
          'head -c 5 ${shellQuote('${uvMount.path}/probe.txt')}',
        );
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(result.stdout.toString(), contains('seed-ok'));
        expect(result.stdout.toString(), contains('probe'));
      });

      test('the broader ro mount still confines the workspace around the '
          'child', () async {
        final result = await run(
          'printf nope > ${shellQuote('${workspace.path}/sibling.txt')}',
        );
        expect(result.exitCode, isNot(0));
      });
    },
    skip: !_hasSandboxExec
        ? 'live nested-rw leg: sandbox-exec not on this host'
        : _hostAlreadySandboxed
        ? 'live nested-rw leg: host is itself sandboxed (nested sandbox '
              'profiles intersect — an inner allow cannot lift an outer deny)'
        : false,
  );
}
