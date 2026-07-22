import 'package:fa/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lua runs in the WASM sandbox', (tester) async {
    final env = await createPlatformEnv();

    // Version banner (gopher-lua VM, Lua 5.1 semantics — see ATTRIBUTION.md).
    var r = await env.exec('lua -v');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('Lua 5.1'));

    // Inline eval with the string/table/math stdlib.
    r = await env.exec(
      "lua -e 'local t={1,2,3}; for i,v in ipairs(t) do t[i]=v*v end; "
      'print(table.concat(t,",")); print(string.format("%.2f", math.pi))\'',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('1,4,9'));
    expect(r.valueOrNull?.stdout, contains('3.14'));

    // pcall catches runtime errors inside the interpreter.
    r = await env.exec(
      'lua -e \'local ok = pcall(function() error("boom") end); print(ok)\'',
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout.trim(), 'false');

    // Script file with the io library, reading a sandbox file; script
    // arguments arrive via the `arg` table.
    await env.exec('mkdir -p /lua_demo');
    await env.exec('echo "hello from fs" > /lua_demo/data.txt');
    final written = await env.writeFile(
      '/lua_demo/script.lua',
      'local f = assert(io.open("/lua_demo/data.txt", "r"))\n'
          'local text = f:read("*a"):gsub("%s+\$", "")\n'
          'f:close()\n'
          'print(text)\n'
          'print("arg1=" .. tostring(arg[1]))\n',
    );
    expect(written.isOk, isTrue, reason: '${written.errorOrNull}');

    r = await env.exec('lua /lua_demo/script.lua world');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('hello from fs'));
    expect(r.valueOrNull?.stdout, contains('arg1=world'));

    // Relative script path resolves after cd.
    r = await env.exec('cd /lua_demo && lua script.lua');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('hello from fs'));

    // Piped input becomes the script file (same plumbing as python3/qjs).
    r = await env.exec("echo 'print(6 * 7)' | lua");
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout.trim(), '42');

    // os.exit codes propagate.
    r = await env.exec("lua -e 'os.exit(3)'");
    expect(r.valueOrNull?.exitCode, 3);

    // Uncaught errors reach stderr with a non-zero exit code.
    r = await env.exec('lua -e \'error("boom")\'');
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, contains('boom'));
  });
}
