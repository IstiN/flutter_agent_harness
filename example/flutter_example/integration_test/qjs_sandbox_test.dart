import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('qjs runs JavaScript in the WASM sandbox', (tester) async {
    final env = await createPlatformEnv();

    // Inline eval with JSON.
    var r = await env.exec(
      'qjs -e \'console.log(JSON.stringify({js: "quickjs", ok: true}))\'',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('"ok":true'));

    // Modern JS syntax (map, arrow functions, template literals).
    r = await env.exec(
      "qjs -e 'const a=[1,2,3]; console.log(a.map(x=>x*2).join(\",\"));'",
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout.trim(), '2,4,6');

    // Script file with the qjs:std module, reading a sandbox file.
    await env.exec('mkdir -p /js_demo');
    await env.exec('echo "hello from fs" > /js_demo/data.txt');
    final written = await env.writeFile(
      '/js_demo/script.js',
      'import * as std from "qjs:std";\n'
          'const text = std.loadFile("/js_demo/data.txt").trim();\n'
          'const nums = [1,2,3].map(x => x * x);\n'
          'console.log(text + " | " + nums.join(","));\n',
    );
    expect(written.isOk, isTrue, reason: '${written.errorOrNull}');

    r = await env.exec('qjs /js_demo/script.js');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('hello from fs | 1,4,9'));

    // Relative script path resolves after cd.
    r = await env.exec('cd /js_demo && qjs script.js');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('hello from fs'));

    // The `js` alias works too.
    r = await env.exec("js -e 'console.log(6 * 7)'");
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout.trim(), '42');

    // Errors reach stderr with a non-zero exit code.
    r = await env.exec("qjs -e 'throw new Error(\"boom\")'");
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, contains('boom'));
  });
}
