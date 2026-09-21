/// Live macOS kernel-mode confinement check for an L1-shaped cube: under
/// `sandbox-exec` the payload cannot read `/etc/hosts`, cannot
/// redirect-write above the workspace, and can write inside the workspace
/// and to `/dev/null`.
///
/// Skipped everywhere `sandbox-exec` is unavailable (Linux CI containers);
/// validated on a real macOS host with:
///
/// ```sh
/// dart test test/cube/backends/macos_sandbox_live_test.dart
/// ```
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cube/backends/cube_backend.dart';
import 'package:flutter_agent_harness/src/cube/backends/macos_sandbox.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/fs_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
import 'package:test/test.dart';

/// Whether live kernel enforcement can run on this host.
final bool _liveMacOs =
    Platform.isMacOS &&
    Process.runSync('which', ['sandbox-exec']).exitCode == 0;

/// Whether the HOST itself already sandboxes reads (e.g. an fa cube
/// session): nested sandbox profiles intersect, so the profile under test
/// cannot re-allow what the outer profile denies — the live legs need a
/// clean host (CI macOS leg or a developer machine).
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
    'macOS kernel mode live',
    () {
      late Directory workspace;
      late String profilePath;

      setUp(() {
        workspace = Directory.systemTemp.createTempSync('fah-cube-live-');
        final spec = CubeSpec(
          name: 'l1-core',
          backend: CubeBackendMode.kernel,
          tools: const CubeToolPolicy(allow: {'echo', 'cat'}),
          filesystem: CubeFsPolicy(workspace: workspace.path),
        );
        profilePath = '${workspace.path}/.fah/cube-profiles/live.sb';
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

      /// Runs [command] inside the staged sandbox with the workspace as cwd.
      Future<ProcessResult> run(String command) => Process.run('/bin/sh', [
        '-c',
        'cd ${shellQuote(workspace.path)} && '
            '${const MacOsSandboxBackend().wrapCommand(command, profilePath: profilePath)}',
      ]);

      test('a redirect above the workspace fails', () async {
        final escape = '${workspace.parent.path}/fah-cube-escape.txt';
        final result = await run('echo x > ${shellQuote(escape)}');
        expect(result.exitCode, isNot(0));
        expect(File(escape).existsSync(), isFalse);
      });

      test('a redirect inside the workspace succeeds', () async {
        final result = await run('echo x > out.txt');
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(File('${workspace.path}/out.txt').existsSync(), isTrue);
      });

      test('reading /etc/hosts fails', () async {
        final result = await run('cat /etc/hosts');
        expect(result.exitCode, isNot(0));
        expect(result.stdout, isEmpty);
      });

      test('writing /dev/null succeeds', () async {
        final result = await run('echo x > /dev/null');
        expect(result.exitCode, 0, reason: result.stderr.toString());
      });
    },
    skip: !_liveMacOs
        ? 'live macOS kernel mode: sandbox-exec not on this host'
        : _hostAlreadySandboxed
        ? 'live macOS kernel mode: host is itself sandboxed (nested '
              'sandbox profiles intersect — an inner allow cannot lift an '
              'outer deny)'
        : false,
  );
}
