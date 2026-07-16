import 'package:flutter/material.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('git local porcelain works in the WASM sandbox', (tester) async {
    debugPrint('Creating platform env...');
    final env = await createPlatformEnv();
    debugPrint('Platform env created');

    final versionResult = await env.exec('git --version');
    expect(versionResult.valueOrNull?.exitCode, 0);
    expect(
      versionResult.valueOrNull?.stdout,
      contains('git version'),
      reason: 'git --version should report a version',
    );

    final repoPath = '/git_sandbox_test_repo';
    final hostRepoPath = '${env.cwd}$repoPath';

    debugPrint('Creating repo directory...');
    final mkdirResult = await env.exec('mkdir -p $repoPath');
    expect(mkdirResult.valueOrNull?.exitCode, 0);

    debugPrint('Initializing git repo...');
    final initResult = await env.exec('git init $repoPath');
    expect(initResult.valueOrNull?.exitCode, 0);
    expect(
      initResult.valueOrNull?.stdout,
      contains('Initialized empty Git repository'),
    );

    debugPrint('Writing a file...');
    final echoResult = await env.exec(
      'echo "hello from git sandbox" > $repoPath/readme.txt',
    );
    expect(echoResult.valueOrNull?.exitCode, 0);

    debugPrint('Staging the file...');
    final addResult = await env.exec('git -C $repoPath add readme.txt');
    expect(addResult.valueOrNull?.exitCode, 0);

    debugPrint('Committing...');
    final commitResult = await env.exec(
      'git -C $repoPath commit -m "initial commit"',
    );
    expect(commitResult.valueOrNull?.exitCode, 0);
    expect(
      commitResult.valueOrNull?.stdout,
      contains('initial commit'),
      reason: 'commit output should contain the message',
    );

    debugPrint('Checking log...');
    final logResult = await env.exec('git -C $repoPath log');
    expect(logResult.valueOrNull?.exitCode, 0);
    expect(
      logResult.valueOrNull?.stdout,
      contains('initial commit'),
      reason: 'log should contain the commit message',
    );

    debugPrint('Creating a branch...');
    final branchResult = await env.exec('git -C $repoPath branch feature');
    expect(branchResult.valueOrNull?.exitCode, 0);

    final branchesResult = await env.exec('git -C $repoPath branch');
    expect(branchesResult.valueOrNull?.stdout, contains('* main'));
    expect(branchesResult.valueOrNull?.stdout, contains('feature'));

    debugPrint('Checking out feature branch...');
    final checkoutResult = await env.exec('git -C $repoPath checkout feature');
    expect(checkoutResult.valueOrNull?.exitCode, 0);
    expect(
      checkoutResult.valueOrNull?.stdout,
      contains("Switched to branch 'feature'"),
    );

    debugPrint('Checking status...');
    final statusResult = await env.exec('git -C $repoPath status');
    expect(statusResult.valueOrNull?.exitCode, 0);
    expect(
      statusResult.valueOrNull?.stdout,
      contains('working tree clean'),
      reason: 'status should report a clean working tree',
    );

    debugPrint('Showing HEAD commit...');
    final showResult = await env.exec('git -C $repoPath show HEAD');
    expect(showResult.valueOrNull?.exitCode, 0);
    expect(showResult.valueOrNull?.stdout, contains('initial commit'));

    debugPrint('Reading blob via cat-file...');
    final catFileResult = await env.exec(
      'git -C $repoPath cat-file -p HEAD:readme.txt',
    );
    expect(catFileResult.valueOrNull?.exitCode, 0);
    expect(
      catFileResult.valueOrNull?.stdout,
      contains('hello from git sandbox'),
    );

    debugPrint('Hashing an object...');
    final hashResult = await env.exec(
      'git -C $repoPath hash-object readme.txt',
    );
    expect(hashResult.valueOrNull?.exitCode, 0);
    expect(
      hashResult.valueOrNull?.stdout.trim().length,
      40,
      reason: 'hash-object should return a 40-char SHA-1',
    );

    // Render a tiny UI so the screenshot reflects the test state.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: Text('git tests passed: $hostRepoPath')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'git_sandbox_tests',
    );
  });

  testWidgets('git clone rejects non-GitHub URLs in the subset', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    final result = await env.exec(
      'git clone https://example.com/repo.git /unsupported_clone',
    );
    expect(result.valueOrNull?.exitCode, isNot(0));
    expect(
      result.valueOrNull?.stderr,
      contains('only public GitHub HTTPS URLs are supported'),
    );
  });

  testWidgets('git clone downloads a public GitHub repo archive', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    final result = await env.exec(
      'git clone https://github.com/IstiN/flutter_agent_harness.git /github_clone',
    );
    expect(result.valueOrNull?.exitCode, 0, reason: result.valueOrNull?.stderr);
    debugPrint('CLONE stdout: ${result.valueOrNull?.stdout}');
    debugPrint('CLONE stderr: ${result.valueOrNull?.stderr}');
    expect(
      result.valueOrNull?.stdout,
      contains('Cloned into'),
      reason: 'clone should report success',
    );

    final lsResult = await env.exec('ls /github_clone');
    expect(lsResult.valueOrNull?.exitCode, 0);
    expect(
      lsResult.valueOrNull?.stdout,
      contains('README.md'),
      reason: 'cloned repo should contain README.md',
    );

    final gitDirResult = await env.exec('ls /github_clone/.git');
    expect(gitDirResult.valueOrNull?.exitCode, 0);
  });
}
