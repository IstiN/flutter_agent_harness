import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cd/pwd builtins persist working directory across exec calls', (
    tester,
  ) async {
    final env = await createPlatformEnv();

    var result = await env.exec(
      'mkdir -p /builtins/sub && cd /builtins/sub && pwd',
    );
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), '/builtins/sub');

    // cwd persists across separate exec calls.
    result = await env.exec('pwd');
    expect(result.valueOrNull?.stdout.trim(), '/builtins/sub');

    result = await env.exec('cd .. && pwd');
    expect(result.valueOrNull?.stdout.trim(), '/builtins');

    // Relative redirect resolves against the current directory.
    result = await env.exec('echo data > rel.txt && cat rel.txt');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), 'data');

    result = await env.exec('cat /builtins/rel.txt');
    expect(result.valueOrNull?.stdout.trim(), 'data');

    // cd to a missing directory fails and keeps the old cwd.
    result = await env.exec('cd /nope && pwd || pwd');
    expect(result.valueOrNull?.stdout.trim(), '/builtins');
  });

  testWidgets('export/unset builtins and \$VAR expansion work', (tester) async {
    final env = await createPlatformEnv();

    var result = await env.exec(
      'export FAH_GREETING=hello && echo \$FAH_GREETING',
    );
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), 'hello');

    // Exported values persist across exec calls.
    result = await env.exec('echo \${FAH_GREETING} world');
    expect(result.valueOrNull?.stdout.trim(), 'hello world');

    // Expansion works inside double quotes but not single quotes.
    result = await env.exec('echo "a \$FAH_GREETING b"');
    expect(result.valueOrNull?.stdout.trim(), 'a hello b');
    result = await env.exec("echo 'a \$FAH_GREETING b'");
    expect(result.valueOrNull?.stdout.trim(), 'a \$FAH_GREETING b');

    // WASM applets see exported variables too.
    result = await env.exec('printenv FAH_GREETING');
    expect(result.valueOrNull?.stdout.trim(), 'hello');

    // export with no args lists the variable.
    result = await env.exec('export');
    expect(
      result.valueOrNull?.stdout,
      contains('declare -x FAH_GREETING="hello"'),
    );

    // unset removes it.
    result = await env.exec('unset FAH_GREETING && echo "[\$FAH_GREETING]"');
    expect(result.valueOrNull?.stdout.trim(), '[]');
  });

  testWidgets('grep builtin maps to ripgrep with grep semantics', (
    tester,
  ) async {
    final env = await createPlatformEnv();

    await env.exec('printf "alpha\nBeta\ngamma\n" > /builtins/g.txt');

    var result = await env.exec('grep Beta /builtins/g.txt');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), 'Beta');

    result = await env.exec('grep -i beta /builtins/g.txt');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), 'Beta');

    result = await env.exec('grep missing /builtins/g.txt');
    expect(result.valueOrNull?.exitCode, 1);

    result = await env.exec('grep -c a /builtins/g.txt');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), '3');

    // grep reads from a pipe.
    result = await env.exec('printf "x\ny\nz\n" | grep y');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), 'y');

    // -q is quiet but keeps the exit code.
    result = await env.exec('grep -q gamma /builtins/g.txt');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout, isEmpty);
  });

  testWidgets('extra coreutils applets run in the sandbox', (tester) async {
    final env = await createPlatformEnv();

    var result = await env.exec('expr 20 + 22');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), '42');

    await env.exec('printf "one\ntwo\nthree\n" > /builtins/t.txt');
    result = await env.exec('tac /builtins/t.txt');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout, 'three\ntwo\none\n');

    result = await env.exec('du -s /builtins');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout, isNotEmpty);

    result = await env.exec('stat /builtins/t.txt');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout, contains('File:'));

    result = await env.exec('id');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout, contains('uid='));

    result = await env.exec('realpath /builtins/../builtins/t.txt');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), '/builtins/t.txt');

    result = await env.exec('relpath /builtins/sub /builtins');
    expect(result.valueOrNull?.exitCode, 0);
    expect(result.valueOrNull?.stdout.trim(), 'sub');
  });

  testWidgets('wget downloads files like curl', (tester) async {
    final env = await createPlatformEnv();
    var result = await env.exec(
      'wget -q -O /builtins/example.html https://example.com',
    );
    expect(result.valueOrNull?.exitCode, 0);
    result = await env.exec('grep -i "Example Domain" /builtins/example.html');
    expect(result.valueOrNull?.exitCode, 0);
  });
}
