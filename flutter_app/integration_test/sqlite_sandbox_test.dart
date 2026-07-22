import 'package:fa/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sqlite3 works in the WASM sandbox', (tester) async {
    final env = await createPlatformEnv();
    await env.exec('rm -f /demo.db');

    var r = await env.exec('sqlite3 --version');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('3.'));

    // Create a table, insert rows, and query with a math function.
    r = await env.exec(
      "sqlite3 /demo.db \"CREATE TABLE t(x TEXT, n INTEGER); "
      "INSERT INTO t VALUES ('hello', 42), ('world', 7);\"",
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);

    r = await env.exec('sqlite3 /demo.db "SELECT x, n*n FROM t ORDER BY n;"');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('world|49'));
    expect(r.valueOrNull?.stdout, contains('hello|1764'));

    // The database file persists across exec calls.
    r = await env.exec('sqlite3 /demo.db "SELECT count(*) FROM t;"');
    expect(r.valueOrNull?.exitCode, 0);
    expect(r.valueOrNull?.stdout.trim(), '2');

    // SQL from stdin via a pipe is not available, but -cmd/readonly and
    // file queries work; check a syntax error surfaces with non-zero exit.
    r = await env.exec('sqlite3 /demo.db "SELEC nonsense;"');
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, contains('error'));
  });
}
