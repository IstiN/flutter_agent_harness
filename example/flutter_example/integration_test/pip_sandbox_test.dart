import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pip installs pure-python wheels for sandbox python3', (
    tester,
  ) async {
    final env = await createPlatformEnv();

    // Install a small pure-Python wheel from the real PyPI (this file runs
    // on-device only, where network is available).
    var r = await env.exec('pip install six');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('Successfully installed six-'));

    // The wheel landed in site-packages and python3 imports it (PYTHONPATH).
    r = await env.exec(
      "python3 -c 'import six; print(\"six\", six.__version__)'",
    );
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('six 1.'));

    // pip list/show read the dist-info metadata back.
    r = await env.exec('pip list');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('six'));

    r = await env.exec('pip show six');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('Name: six'));
    expect(r.valueOrNull?.stdout, contains('site-packages'));

    // Binary-only wheels are refused with a clear message and exit 1.
    r = await env.exec('pip install grpcio');
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, contains('no pure-Python wheel'));

    // Uninstall removes the package; python3 can no longer import it.
    r = await env.exec('pip uninstall six');
    expect(r.valueOrNull?.exitCode, 0, reason: r.valueOrNull?.stderr);
    expect(r.valueOrNull?.stdout, contains('Successfully uninstalled six-'));

    r = await env.exec('pip list');
    expect(r.valueOrNull?.stdout, isNot(contains('six')));

    r = await env.exec("python3 -c 'import six'");
    expect(r.valueOrNull?.exitCode, isNot(0));
    expect(r.valueOrNull?.stderr, contains('ModuleNotFoundError'));
  });
}
