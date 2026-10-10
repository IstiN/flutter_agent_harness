// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1444 AC4 (IT-secret-presence) — the sandbox `env` listing proves
// secret presence without leaking values, identically on the web
// MemoryShell and the mobile WasiSandboxShell (Dart builtin, no WASM
// needed). Byte-scans assert no secret material reaches any result.

import 'package:fa/sandbox/memory_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'ghp_supersecrettokenvalue42';
const _otherValue = 'plain-non-secret-value';

void main() {
  test('env renders PRESENT for a granted secret, value never renders',
      () async {
    final shell = MemoryShell();
    final inner = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(inner);
    final env = SecretsExecutionEnv(inner, {'FA_GITHUB_TOKEN': _token});

    final result = await env.exec('env');
    expect(result.isOk, isTrue);
    final out = result.valueOrNull!.stdout;
    expect(out, contains('FA_GITHUB_TOKEN: PRESENT'));
    expect(out.contains(_token), isFalse,
        reason: 'secret VALUE must never render in env output');
  });

  test('env renders ABSENT for a rostered revoked secret (E3)', () async {
    final shell = MemoryShell();
    final inner = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(inner);
    final env = SecretsExecutionEnv(inner, {'FA_GITHUB_TOKEN': _token});
    env.revokeSecret('FA_GITHUB_TOKEN');

    final out = (await env.exec('env')).valueOrNull!.stdout;
    expect(out, contains('FA_GITHUB_TOKEN: ABSENT'));
    expect(out.contains(_token), isFalse);
  });

  test('plain shell vars keep NAME=value; the roster var stays hidden',
      () async {
    final shell = MemoryShell();
    final inner = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(inner);
    final env = SecretsExecutionEnv(inner, {
      'FA_GITHUB_TOKEN': _token,
      'OTHER_KEY': _otherValue,
    });

    final out = (await env.exec('env')).valueOrNull!.stdout;
    // Every wrapper-injected name renders presence-only; plain shell vars
    // (HOME/PATH/SHELL) keep the classic NAME=value form.
    expect(out, contains('FA_GITHUB_TOKEN: PRESENT'));
    expect(out, contains('OTHER_KEY: PRESENT'));
    expect(out, contains('HOME=/'));
    expect(out, contains('SHELL=/bin/sh'));
    expect(out, contains('PATH=/bin'));
    expect(out.contains('$secretPresenceEnvVar='), isFalse);
    expect(out.contains(_token), isFalse);
    expect(out.contains(_otherValue), isFalse);
  });

  test('bash still expands the granted value (\$NAME works)', () async {
    final shell = MemoryShell();
    final inner = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(inner);
    final env = SecretsExecutionEnv(inner, {'FA_GITHUB_TOKEN': _token});

    final out =
        (await env.exec('printf %s "\$FA_GITHUB_TOKEN"')).valueOrNull!.stdout;
    expect(out, _token);
  });
}
