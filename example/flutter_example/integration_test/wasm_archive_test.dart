// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration smoke test for the new WASM utilities: sed, awk, tar, gzip,
/// zip/unzip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sed, awk, tar, gzip, zip/unzip in WASM sandbox', (tester) async {
    final env = await createPlatformEnv();

    Future<ShellExecResult> run(String command) async {
      final result = await env.exec(command);
      if (result.isErr) {
        fail('"$command" failed: ${result.errorOrNull!}');
      }
      return result.valueOrNull!;
    }

    await env.writeFile('fruits.txt', 'cherry\napple\nbanana\napple\n');
    await env.writeFile('words.txt', 'alpha\nbeta\ngamma\n');

    // sed
    final sed = await run("echo 'hello world' | sed 's/world/earth/'");
    expect(sed.stdout.trim(), 'hello earth');

    // awk
    final awk = await run("echo '1 2 3' | awk '{print \$1 + \$2 + \$3}'");
    expect(awk.stdout.trim(), '6');

    // tar
    await run('tar -cf /archive.tar /fruits.txt /words.txt');
    await run('mkdir /tar_out');
    await run('tar -xf /archive.tar -C /tar_out');
    expect(
      (await run('cat /tar_out/fruits.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );
    await run('rm -r /tar_out /archive.tar');

    // gzip
    await run('cp /fruits.txt /fruits_copy.txt');
    await run('gzip /fruits_copy.txt');
    expect((await run('ls /')).stdout, contains('fruits_copy.txt.gz'));
    await run('gzip -d /fruits_copy.txt.gz');
    expect(
      (await run('cat /fruits_copy.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );
    await run('rm /fruits_copy.txt');

    // zip/unzip
    await run('zip /archive.zip /fruits.txt /words.txt');
    await run('mkdir /zip_out');
    await run('unzip /archive.zip -d /zip_out');
    expect(
      (await run('cat /zip_out/fruits.txt')).stdout,
      'cherry\napple\nbanana\napple\n',
    );
    await run('rm -r /zip_out /archive.zip');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: Text('WASM archive smoke: ok'))),
      ),
    );
    await tester.pumpAndSettle();
    await IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(
      'wasm_archive_smoke',
    );
  });
}
