import 'package:flutter/foundation.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end test of the full git workflow against the real public fixture
/// repo https://github.com/IstiN/fah-git-test (created for exactly this).
///
/// Pushing requires a GitHub token with `repo` scope for IstiN, supplied via
/// `--dart-define=GITHUB_TOKEN=...`. The token is never committed. When the
/// define is absent the test skips itself.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const token = String.fromEnvironment('GITHUB_TOKEN');
  const repoUrl = 'https://github.com/IstiN/fah-git-test.git';

  testWidgets('live workflow: clone/commit/push/branch/push/fetch', (
    tester,
  ) async {
    if (token.isEmpty) {
      debugPrint('GITHUB_TOKEN not set via --dart-define: skipping live test');
      return;
    }
    final env = await createPlatformEnv();
    final tokenEnv = ShellExecOptions(env: {'GITHUB_TOKEN': token});
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final pushedFile = 'push_test_$stamp.txt';
    final branchName = 'fah-test-$stamp';

    // 1. Clone the public fixture repo (no auth needed).
    await env.exec('rm -rf /wt /wt2');
    var r = await env.exec('git clone $repoUrl /wt');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(
      (await env.exec('ls /wt')).valueOrNull?.stdout,
      contains('README.md'),
    );

    // 2. Commit a unique file on main.
    r = await env.exec(
      'echo "push test $stamp" > /wt/$pushedFile && '
      'git -C /wt add $pushedFile && '
      'git -C /wt commit -m "test: push $stamp"',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);

    // 3. Push main (auth via GITHUB_TOKEN in the shell environment).
    r = await env.exec('git -C /wt push origin main', options: tokenEnv);
    expect(
      r.valueOrNull?.exitCode,
      0,
      reason: 'push main failed: ${r.valueOrNull?.stderr}',
    );

    // 4. Create a branch, commit, push the branch.
    r = await env.exec('git -C /wt checkout -b $branchName');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec(
      'echo "branch content" > /wt/branch_$stamp.txt && '
      'git -C /wt add branch_$stamp.txt && '
      'git -C /wt commit -m "test: branch $stamp"',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec('git -C /wt push origin $branchName', options: tokenEnv);
    expect(
      r.valueOrNull?.exitCode,
      0,
      reason: 'push branch failed: ${r.valueOrNull?.stderr}',
    );

    // 5. Fetch and confirm the remote branch is visible locally.
    r = await env.exec('git -C /wt fetch origin');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec('git -C /wt branch -r');
    expect(r.valueOrNull?.stdout, contains('origin/main'));
    expect(r.valueOrNull?.stdout, contains('origin/$branchName'));

    // 6. A fresh clone must contain the file pushed to main.
    r = await env.exec('git clone $repoUrl /wt2');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec('cat /wt2/$pushedFile');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('push test $stamp'));

    // 7. Cross-check via the GitHub API through the shell's curl builtin
    // ($GITHUB_TOKEN expands from the exported shell env).
    r = await env.exec(
      'export GITHUB_TOKEN=$token && '
      'curl -s -H "Authorization: Bearer \$GITHUB_TOKEN" '
      'https://api.github.com/repos/IstiN/fah-git-test/branches',
    );
    expect(r.valueOrNull?.exitCode, 0);
    expect(r.valueOrNull?.stdout, contains(branchName));

    // 8. Cleanup: delete the temporary branch via the API.
    r = await env.exec(
      'curl -s -X DELETE -H "Authorization: Bearer \$GITHUB_TOKEN" '
      'https://api.github.com/repos/IstiN/fah-git-test/git/refs/heads/$branchName',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
  });
}
