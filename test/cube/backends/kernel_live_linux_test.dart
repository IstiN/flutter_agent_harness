@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cube/backends/linux_unshare.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/network_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/resource_limits.dart';
import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
import 'package:test/test.dart';

/// Live [LinuxUnshareBackend] enforcement on a host where user namespaces
/// work (`unshare --user --map-root-user true` exits 0). Skips cleanly
/// everywhere else — CI containers typically answer the probe with EPERM.
Future<void> main() async {
  final userns = await _probeUserNamespaces();
  final skip = userns
      ? null
      : 'user namespaces unavailable (unshare --user --map-root-user '
            'exited non-zero)';

  test('a wrapped echo executes inside the namespace', () async {
    final result = await _run(
      CubeSpec(
        name: 'live',
        tools: const CubeToolPolicy(allow: {'echo'}),
      ),
      'echo fa-cube-live',
    );
    expect(result.exitCode, 0);
    expect(result.stdout, contains('fa-cube-live'));
  }, skip: skip);

  test('memoryBytes becomes an enforced ulimit -v ceiling', () async {
    final spec = CubeSpec(
      name: 'live',
      tools: const CubeToolPolicy(allow: {'bash'}),
      resources: const CubeResourceLimits(memoryBytes: 512 * 1024 * 1024),
    );
    // The ceiling is observable inside the namespace: 512 MiB in KiB.
    final observed = await _run(spec, 'ulimit -v');
    expect(observed.exitCode, 0);
    expect(observed.stdout.trim(), '524288');
    // And it bites: a ~572 MB command substitution exceeds the cap.
    final overAlloc = await _run(
      spec,
      r'x=$(head -c 600000000 /dev/zero | base64)',
    );
    expect(overAlloc.exitCode, isNot(0));
  }, skip: skip);

  test('--net blocks name resolution', () async {
    final result = await _run(
      CubeSpec(
        name: 'live',
        tools: const CubeToolPolicy(allow: {'getent'}),
        network: const CubeNetworkPolicy(),
      ),
      'getent hosts example.com',
    );
    expect(result.exitCode, isNot(0));
  }, skip: skip);
}

/// The same probe the backend relies on: a non-zero exit (typically EPERM
/// without user namespaces) or a missing `unshare` binary means the live
/// tests cannot run and must skip.
Future<bool> _probeUserNamespaces() async {
  try {
    final probe = await Process.run('unshare', [
      '--user',
      '--map-root-user',
      'true',
    ]);
    return probe.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Wraps [command] in the Linux backend and runs the wrapper line under
/// bash, like the harness exec does.
Future<ProcessResult> _run(CubeSpec spec, String command) {
  final wrapped = LinuxUnshareBackend(
    spec: spec,
  ).wrapCommand(command, profilePath: '/tmp/fa-cube-live.sb');
  return Process.run('/bin/bash', ['-c', wrapped]);
}
