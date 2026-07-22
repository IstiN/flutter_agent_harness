import 'package:fa/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('git remote add/-v/get-url/remove work', (tester) async {
    final env = await createPlatformEnv();
    await env.exec('rm -rf /r1 && git init /r1');

    var r = await env.exec(
      'git -C /r1 remote add origin https://example.com/x/y.git',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);

    r = await env.exec('git -C /r1 remote');
    expect(r.valueOrNull?.stdout, contains('origin'));

    r = await env.exec('git -C /r1 remote -v');
    expect(r.valueOrNull?.stdout, contains('origin'));
    expect(r.valueOrNull?.stdout, contains('https://example.com/x/y.git'));

    r = await env.exec('git -C /r1 remote get-url origin');
    expect(r.valueOrNull?.stdout.trim(), 'https://example.com/x/y.git');

    r = await env.exec('git -C /r1 remote add origin https://dup.example.com');
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, contains('already exists'));

    r = await env.exec('git -C /r1 remote remove origin');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec('git -C /r1 remote');
    expect(r.valueOrNull?.stdout.trim(), isEmpty);
  });

  testWidgets('git branch -r/-a do not crash on flag-only args', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    await env.exec('rm -rf /r2 && git init /r2');
    await env.exec('echo hi > /r2/a.txt && git -C /r2 add a.txt');
    await env.exec('git -C /r2 commit -m init');

    var r = await env.exec('git -C /r2 branch -r');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);

    r = await env.exec('git -C /r2 branch -a');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('* main'));

    r = await env.exec('git -C /r2 branch --bogus');
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, isNot(contains('No element')));
  });

  testWidgets('git checkout -b creates and switches to a new branch', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    await env.exec('rm -rf /r3 && git init /r3');
    await env.exec('echo hi > /r3/a.txt && git -C /r3 add a.txt');
    await env.exec('git -C /r3 commit -m init');

    var r = await env.exec('git -C /r3 checkout -b feature');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('feature'));

    r = await env.exec('git -C /r3 branch');
    expect(r.valueOrNull?.stdout, contains('* feature'));

    // -b from an explicit start point.
    r = await env.exec('git -C /r3 checkout -b from-main main');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec('git -C /r3 branch');
    expect(r.valueOrNull?.stdout, contains('* from-main'));

    // A clear error for an unknown start point (no crash).
    r = await env.exec('git -C /r3 checkout -b nope origin/master');
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, isNot(contains('GitRefNotFound')));
  });

  testWidgets('rm -rf removes a repo with committed loose objects', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    await env.exec('rm -rf /r4 && git init /r4');
    await env.exec('echo one > /r4/a.txt && echo two > /r4/b.txt');
    await env.exec('git -C /r4 add a.txt b.txt && git -C /r4 commit -m c1');
    await env.exec('echo three >> /r4/a.txt');
    await env.exec('git -C /r4 add a.txt && git -C /r4 commit -m c2');

    var r = await env.exec('ls /r4/.git/objects');
    expect(r.valueOrNull?.stdout, isNotEmpty);

    r = await env.exec('rm -rf /r4');
    expect(
      r.valueOrNull?.exitCode,
      0,
      reason: 'rm -rf must delete .git trees: ${r.valueOrNull?.stderr}',
    );

    r = await env.exec('ls /r4');
    expect(r.valueOrNull?.exitCode, isNot(0));
  });

  testWidgets('git clone reports destination-exists like real git', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    await env.exec('rm -rf /exists && mkdir -p /exists && touch /exists/f');

    final r = await env.exec(
      'git clone https://github.com/IstiN/flutter_agent_harness.git /exists',
    );
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, contains('already exists'));
    expect(r.valueOrNull?.stderr, isNot(contains('GitRepoExists')));
  });

  testWidgets('clone writes origin refs; branch -r, fetch, checkout -b work', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    await env.exec('rm -rf /fc');

    var r = await env.exec(
      'git clone https://github.com/IstiN/flutter_agent_harness.git /fc',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);

    // The clone must record refs/remotes/origin/* for branch -r and
    // origin/<branch> checkouts.
    r = await env.exec('git -C /fc branch -r');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('origin/main'));

    r = await env.exec('git -C /fc remote -v');
    expect(r.valueOrNull?.stdout, contains('origin'));
    expect(r.valueOrNull?.stdout, contains('github.com'));

    // fetch is a no-op when up to date but must not error.
    r = await env.exec('git -C /fc fetch origin');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);

    // checkout -b from a remote ref.
    r = await env.exec('git -C /fc checkout -b topic origin/main');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    r = await env.exec('git -C /fc branch');
    expect(r.valueOrNull?.stdout, contains('* topic'));

    // Detached checkout of a remote ref.
    r = await env.exec('git -C /fc checkout origin/main');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
  });
}
