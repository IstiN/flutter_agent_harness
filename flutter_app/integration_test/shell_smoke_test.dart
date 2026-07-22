import 'package:flutter/material.dart';
import 'package:fa/env_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shell runs echo on startup', (tester) async {
    debugPrint('Creating platform env...');
    final env = await createPlatformEnv();
    debugPrint('Platform env created');

    debugPrint('Running true...');
    final trueResult = await env.exec('true');
    final trueExit = trueResult.valueOrNull?.exitCode;
    debugPrint('TRUE exitCode: $trueExit');
    expect(trueExit, 0, reason: 'true should exit with code 0');

    debugPrint('Running echo...');
    final echoResult = await env.exec('echo hello from wasm bash');
    final echoExit = echoResult.valueOrNull?.exitCode;
    final echoStdout = echoResult.valueOrNull?.stdout;
    debugPrint('ECHO stdout: $echoStdout');
    debugPrint('ECHO exitCode: $echoExit');
    expect(echoExit, 0, reason: 'echo should exit with code 0');
    expect(
      echoStdout,
      contains('hello from wasm bash'),
      reason: 'echo should print the provided text',
    );

    debugPrint('Running ls...');
    final lsResult = await env.exec('ls /');
    final lsExit = lsResult.valueOrNull?.exitCode;
    final lsStdout = lsResult.valueOrNull?.stdout;
    debugPrint('LS stdout: $lsStdout');
    debugPrint('LS exitCode: $lsExit');
    expect(lsExit, 0, reason: 'ls should exit with code 0');

    final echoText = echoStdout?.trim() ?? '';
    final lsLines = lsStdout?.trim().split('\\n').length ?? 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'true: $trueExit, '
              'echo: $echoText, '
              'ls lines: $lsLines',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
}
