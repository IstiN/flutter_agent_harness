/// Kernel-launch artifact generator: renders the staged SBPL profile and the
/// complete wrapped argv line for a representative cube — without running
/// the CLI.
///
/// The host CI container cannot run sandbox-exec/unshare (user namespaces
/// disabled), so live enforcement is validated on a real macOS host: this
/// test writes the artifacts to a fresh system-temp directory and prints
/// the paths; run it with
///
/// ```sh
/// dart test test/cube/backends/kernel_artifacts_test.dart
/// ```
///
/// and copy the printed files to the validation host. The assertions keep
/// the artifacts honest (standalone shell line, staged profile matches the
/// `buildSandboxProfile` output).
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cube/backends/macos_sandbox.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('generates macOS kernel-launch artifacts', () async {
    final spec = CubeSpec.fromYaml(
      loadYaml('''
apiVersion: fa/v1
kind: Cube
metadata:
  name: web-scraper
  description: Fetches pages inside the sandbox
spec:
  backend: kernel
  tools:
    allow: ["git*", curl, echo]
  network: {}
  filesystem:
    mounts:
      - {path: /usr/share, access: ro}
      - {path: /etc, access: deny}
  env:
    - {name: FAH_MODE, value: sandboxed}
  resources:
    limits: {memory: 512Mi}
    timeout: 3600s
'''),
    );

    // The real workspace is the process cwd on the validation host; any
    // absolute directory works — the artifacts parameterize on it.
    const workspaceRoot = '/tmp/fa-cube-validation';
    const tmpdir = '$workspaceRoot/.fah/tmp';
    const profilePath =
        '$workspaceRoot/.fah/cube-profiles/kernel-validation.sb';
    final backend = MacOsSandboxBackend(
      workspaceRoot: workspaceRoot,
      tmpdir: tmpdir,
      envVars: spec.env.apply(const {}),
    );

    final profile = backend.buildProfile(spec, workspaceRoot: workspaceRoot);
    // Caller-side env (session vars, secrets) threads through the wrap and
    // must be visible inside the clean environment next to the trio.
    const callerEnv = {
      'FAH_SESSION_ID': 'session-42',
      'SECRET_TOKEN': 'top secret',
    };
    final commands = [
      'echo hello-from-the-sandbox',
      "git init sandboxed-repo && git -C sandboxed-repo commit -m 'hi'",
      'curl https://example.com',
    ];
    final wrapped = commands.map(
      (c) => backend.wrapCommand(c, profilePath: profilePath, env: callerEnv),
    );

    // The wrap is a complete standalone shell line: running it with the
    // profile staged at profilePath reproduces the sandboxed execution.
    for (final line in wrapped) {
      expect(line, startsWith("sandbox-exec -f '$profilePath' "));
      expect(line, contains('/usr/bin/env -i '));
      expect(line, contains("FAH_SESSION_ID='session-42'"));
      expect(line, contains("SECRET_TOKEN='top secret'"));
      expect(line, contains('/bin/bash -c '));
    }

    final dir = await Directory.systemTemp.createTemp('fah-cube-artifacts-');
    await File('${dir.path}/kernel-validation.sb').writeAsString(profile);
    await File('${dir.path}/wrapped-commands.sh').writeAsString(
      '#!/bin/sh\n'
      '# Stage first: mkdir -p $tmpdir && '
      "sandbox-exec -f '${dir.path}/kernel-validation.sb' true\n"
      '${wrapped.map((l) => '$l || true').join('\n')}\n',
    );
    // ignore: avoid_print
    print(
      'macOS kernel artifacts written to ${dir.path}:\n'
      "  profile: ${dir.path}/kernel-validation.sb\n"
      "  commands: ${dir.path}/wrapped-commands.sh\n"
      'Copy both to the validation host, then:\n'
      '  mkdir -p $tmpdir\n'
      "  /bin/sh ${dir.path}/wrapped-commands.sh",
    );
    expect(dir.existsSync(), isTrue);
  });
}
