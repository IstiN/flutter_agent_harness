import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end SSH test against https://github.com/IstiN/fah-git-test using a
/// deploy key registered on that repo.
///
/// The private key (PEM, base64-encoded) is supplied via
/// `--dart-define=SSH_TEST_KEY=...`; it is never committed. When the define
/// is absent the test skips itself. `GITHUB_TOKEN` is only needed for the
/// final API cross-check.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const sshKeyB64 = String.fromEnvironment('SSH_TEST_KEY');
  const token = String.fromEnvironment('GITHUB_TOKEN');
  const repoSsh = 'git@github.com:IstiN/fah-git-test.git';

  testWidgets('ssh clone/commit/push via deploy key', (tester) async {
    if (sshKeyB64.isEmpty) {
      debugPrint('SSH_TEST_KEY not set via --dart-define: skipping SSH test');
      return;
    }
    final pem = utf8.decode(base64Decode(sshKeyB64));
    final env = await createPlatformEnv();
    final keyEnv = ShellExecOptions(env: {'GIT_SSH_KEY': pem});
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final pushedFile = 'ssh_test_$stamp.txt';

    // 1. Clone over SSH.
    await env.exec('rm -rf /sw');
    var r = await env.exec('git clone $repoSsh /sw', options: keyEnv);
    expect(
      r.valueOrNull?.exitCode,
      0,
      reason: 'ssh clone failed: ${r.valueOrNull?.stderr}',
    );
    expect(
      (await env.exec('ls /sw')).valueOrNull?.stdout,
      contains('README.md'),
    );

    // 2. Commit a unique file on a unique branch (pushing a new branch
    // never requires fast-forward, so the test is immune to races on main).
    final branchName = 'ssh-test-$stamp';
    r = await env.exec('git -C /sw checkout -b $branchName');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec(
      'echo "ssh push test $stamp" > /sw/$pushedFile && '
      'git -C /sw add $pushedFile && '
      'git -C /sw commit -m "test: ssh push $stamp"',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);

    // 3. Push the branch over SSH (origin URL is git@github.com:... from
    // the clone).
    r = await env.exec('git -C /sw push origin $branchName', options: keyEnv);
    expect(
      r.valueOrNull?.exitCode,
      0,
      reason: 'ssh push failed: ${r.valueOrNull?.stderr}',
    );

    // 4. Cross-check via the GitHub API (optional, needs GITHUB_TOKEN).
    if (token.isNotEmpty) {
      r = await env.exec(
        'curl -s -H "Authorization: Bearer $token" '
        'https://api.github.com/repos/IstiN/fah-git-test/contents/$pushedFile?ref=$branchName',
      );
      expect(r.valueOrNull?.exitCode, 0);
      expect(r.valueOrNull?.stdout, contains(pushedFile));

      // 5. Cleanup: delete the branch via the API.
      r = await env.exec(
        'curl -s -X DELETE -H "Authorization: Bearer $token" '
        'https://api.github.com/repos/IstiN/fah-git-test/git/refs/heads/$branchName',
      );
      expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    }
  });
}
