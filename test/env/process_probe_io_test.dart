// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('pidStartSnapshot is stable across owner locale and timezone '
      '(gh-1898)', () async {
    final tmp = await Directory.systemTemp.createTemp('process-probe-test');
    final sleeper = await Process.start('sleep', ['30']);
    addTearDown(() async {
      sleeper.kill();
      await sleeper.exitCode;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final script = File('${tmp.path}/probe.dart');
    await script.writeAsString('''
import 'dart:io';
import 'package:flutter_agent_harness/src/env/process_probe_io.dart';
Future<void> main(List<String> args) async {
  stdout.write(await pidStartSnapshot(int.parse(args.single)) ?? '<null>');
}
''');

    Future<String> probe(Map<String, String> environment) async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        script.path,
        '${sleeper.pid}',
      ], environment: environment);
      expect(
        result.exitCode,
        0,
        reason: 'probe failed: ${result.stdout}\n${result.stderr}',
      );
      final value = result.stdout.toString().trim();
      expect(value, isNotEmpty);
      expect(value, isNot('<null>'));
      return value;
    }

    final utc = await probe(const {'LC_ALL': 'C', 'TZ': 'UTC'});
    final localized = await probe(const {
      'LC_ALL': 'fr_FR.UTF-8',
      'TZ': 'America/New_York',
    });
    expect(localized, utc);
  });
}
