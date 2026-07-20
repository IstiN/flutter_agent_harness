/// Live smoke test for the `lsp` tool against the real Dart analysis
/// server (`dart language-server --protocol=lsp`, shipped with the SDK).
///
/// Hermetic: builds a scratch pub workspace in a temp directory (no
/// `pub get` needed — the fixture uses relative imports only). Skips
/// gracefully when `dart` is not on PATH. Tagged `integration` and
/// therefore excluded from the pre-commit gate (cold-starting the analysis
/// server takes seconds); run manually with:
/// `dart test --tags integration`
@Tags(['integration'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late LocalExecutionEnv env;
  late LspClientManager manager;
  late AgentTool tool;

  final hasDart = _dartOnPath();

  setUpAll(() async {
    if (!hasDart) return;
    workspace = await Directory.systemTemp.createTemp('fah_lsp_smoke_');
    await File(
      '${workspace.path}/pubspec.yaml',
    ).writeAsString('name: smoke\nenvironment:\n  sdk: ^3.0.0\n');
    await Directory('${workspace.path}/lib').create();
    await File('${workspace.path}/lib/b.dart').writeAsString('''
class Greeter {
  void greet(String name) {
    print('Hello, \$name!');
  }
}
''');
    await File('${workspace.path}/lib/main.dart').writeAsString('''
import 'b.dart';

void main() {
  final greeter = Greeter();
  greeter.greet('world');
  undefined_call_here();
}
''');
    env = LocalExecutionEnv(cwd: workspace.path);
    manager = LspClientManager(
      env: env,
      config: LspConfig.defaults(),
      transportFactory: ioLspTransportFactory,
      processId: pid,
      idleTimeout: Duration.zero,
    );
    tool = lspTool(
      env,
      config: LspToolConfig(
        transportFactory: ioLspTransportFactory,
        manager: manager,
        diagnosticsWait: const Duration(seconds: 30),
      ),
    );
  });

  tearDownAll(() async {
    if (!hasDart) return;
    await manager.shutdownAll();
    await workspace.delete(recursive: true);
  });

  Future<String> run(Map<String, dynamic> args) async {
    final result = await tool.execute(args, null, null);
    return result.content.whereType<TextContent>().map((c) => c.text).join();
  }

  test(
    'diagnostics reports the analyzer error',
    () async {
      final output = await run({'op': 'diagnostics', 'path': 'lib/main.dart'});
      expect(output, contains('error'));
      expect(output, contains('undefined_call_here'));
    },
    skip: hasDart ? false : 'dart not on PATH',
  );

  test('definition jumps to the class', () async {
    final output = await run({
      'op': 'definition',
      'path': 'lib/main.dart',
      'line': 4,
      'character': 20,
    });
    expect(output, contains('definition'));
    expect(output, contains('lib/b.dart'));
  }, skip: hasDart ? false : 'dart not on PATH');

  test(
    'references finds the construction site',
    () async {
      final output = await run({
        'op': 'references',
        'path': 'lib/b.dart',
        'line': 1,
        'character': 7,
      });
      expect(output, contains('reference'));
      expect(output, contains('lib/main.dart'));
    },
    skip: hasDart ? false : 'dart not on PATH',
  );

  test(
    'rename updates the declaration and the reference atomically',
    () async {
      final output = await run({
        'op': 'rename',
        'path': 'lib/b.dart',
        'line': 2,
        'character': 8,
        'newName': 'welcome',
      });
      expect(output, contains('Applied rename'));
      final b = await File('${workspace.path}/lib/b.dart').readAsString();
      final main = await File('${workspace.path}/lib/main.dart').readAsString();
      expect(b, contains('void welcome(String name)'));
      expect(main, contains('greeter.welcome('));
    },
    skip: hasDart ? false : 'dart not on PATH',
  );
}

bool _dartOnPath() {
  try {
    final result = Process.runSync('dart', ['--version']);
    return result.exitCode == 0;
  } on Object {
    return false;
  }
}
