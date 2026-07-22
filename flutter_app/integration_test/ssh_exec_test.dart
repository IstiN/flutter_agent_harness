import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fa/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Live SSH exec test for the `ssh` builtin against github.com, using the same
/// deploy key as `git_ssh_test.dart` (registered on
/// https://github.com/IstiN/fah-git-test).
///
/// The private key (PEM, base64-encoded) is supplied via
/// `--dart-define=SSH_TEST_KEY=...`; it is never committed. When the define
/// is absent the test skips itself.
///
/// GitHub's sshd provides no shell and no SFTP subsystem, so this only
/// verifies connect + key auth + the exec channel: GitHub answers any exec
/// request with its "successfully authenticated" greeting and exit status 1.
/// File transfer (scp/sftp) is covered offline by `test/sandbox_ssh_test.dart`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const sshKeyB64 = String.fromEnvironment('SSH_TEST_KEY');

  testWidgets('ssh exec to github.com authenticates with SSH_KEY', (
    tester,
  ) async {
    if (sshKeyB64.isEmpty) {
      debugPrint('SSH_TEST_KEY not set via --dart-define: skipping SSH test');
      return;
    }
    final pem = utf8.decode(base64Decode(sshKeyB64));
    final env = await createPlatformEnv();
    final keyEnv = ShellExecOptions(env: {'SSH_KEY': pem});

    // Key auth + exec channel: GitHub rejects the command with its greeting
    // and exit status 1 — proof the handshake and key auth succeeded.
    var r = await env.exec(
      'ssh git@github.com fah-ssh-builtin-probe',
      options: keyEnv,
    );
    expect(r.valueOrNull?.exitCode, 1, reason: r.valueOrNull?.stderr);
    expect(
      '${r.valueOrNull?.stdout}${r.valueOrNull?.stderr}',
      contains('successfully authenticated'),
    );

    // The ~/.ssh default path: with the key at /.ssh/id_ed25519 the builtin
    // picks it up without SSH_KEY.
    r = await env.exec(
      'mkdir -p /.ssh && printf %s "\$PROBE_KEY" > /.ssh/id_ed25519',
      options: ShellExecOptions(env: {'PROBE_KEY': pem}),
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec('ssh git@github.com fah-ssh-builtin-probe');
    expect(r.valueOrNull?.exitCode, 1, reason: r.valueOrNull?.stderr);
    expect(
      '${r.valueOrNull?.stdout}${r.valueOrNull?.stderr}',
      contains('successfully authenticated'),
    );
    await env.exec('rm -f /.ssh/id_ed25519');

    // Usage errors never touch the network.
    r = await env.exec('ssh git@github.com', options: keyEnv);
    expect(r.valueOrNull?.exitCode, 2);

    // GitHub has no SFTP subsystem: scp fails cleanly with exit 1 (connect
    // and auth still succeeded — the failure is the subsystem request).
    r = await env.exec(
      'scp /nonexistent-local-file git@github.com:/tmp/x',
      options: keyEnv,
    );
    expect(r.valueOrNull?.exitCode, 1);
  });
}
