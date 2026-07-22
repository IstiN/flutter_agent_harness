import 'package:fa/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('python3 runs in the WASM sandbox with stdlib', (tester) async {
    final env = await createPlatformEnv();

    var r = await env.exec('python3 --version');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('Python 3.14'));

    // json + sys from the bundled stdlib.
    r = await env.exec(
      'python3 -c \'import json,sys; print(json.dumps({"py": sys.version_info.major}))\'',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('"py": 3'));

    // re + pathlib from a script file inside the sandbox.
    await env.exec('mkdir -p /py_demo');
    final written = await env.writeFile(
      '/py_demo/script.py',
      'import re, json, pathlib\n'
          'text = pathlib.Path("/py_demo/data.txt").read_text()\n'
          'nums = re.findall(r"\\d+", text)\n'
          'print(json.dumps({"nums": nums}))\n',
    );
    expect(written.isOk, isTrue, reason: '${written.errorOrNull}');
    await env.exec('echo "a1 b22 c333" > /py_demo/data.txt');

    r = await env.exec('python3 /py_demo/script.py');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('"nums": ["1", "22", "333"]'));

    // Relative script path resolves against cd.
    r = await env.exec('cd /py_demo && python3 script.py');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('"nums"'));

    // Exit codes propagate.
    r = await env.exec("python3 -c 'import sys; sys.exit(3)'");
    expect(r.valueOrNull?.exitCode, 3);

    // Tracebacks reach stderr with a non-zero exit code.
    r = await env.exec("python3 -c 'raise ValueError(\"boom\")'");
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, contains('ValueError: boom'));
  });
}
