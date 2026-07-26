// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/app_log.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(AppLog.reset);
  tearDown(AppLog.reset);

  group('AppLog', () {
    test('buffers timestamped, tagged lines and dumps them', () {
      AppLog.i('home', 'listed 3 accessories');
      AppLog.i('boot', 'env created');

      final lines = AppLog.dump().split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], contains('[home] listed 3 accessories'));
      expect(lines[1], contains('[boot] env created'));
      // ISO-8601 UTC timestamp prefix.
      expect(
        lines[0],
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')),
      );
    });

    test('the ring buffer keeps only the last maxLines lines', () {
      for (var i = 0; i < AppLog.maxLines + 10; i++) {
        AppLog.i('test', 'line $i');
      }

      final lines = AppLog.dump().split('\n');
      expect(lines, hasLength(AppLog.maxLines));
      expect(lines.first, contains('line 10'));
      expect(lines.last, contains('line ${AppLog.maxLines + 9}'));
    });

    test('persists appended lines to logs/app.log once attached', () async {
      final env = MemoryExecutionEnv();
      AppLog.attach(env);
      AppLog.i('home', 'hello file');
      await AppLog.flush();

      final content = (await env.readTextFile(
        '${env.cwd}/${AppLog.filePath}',
      )).valueOrNull;
      expect(content, contains('[home] hello file'));
    });

    test('without an env nothing persists and nothing throws', () {
      AppLog.i('home', 'buffered only');
      expect(AppLog.dump(), contains('buffered only'));
    });

    test('the persisted file is trimmed to its tail past the cap', () async {
      final env = MemoryExecutionEnv();
      AppLog.attach(env);
      // ~2.1 KB per line → ~550 lines clear the 1 MB cap.
      final payload = 'x' * 2000;
      for (var i = 0; i < 550; i++) {
        AppLog.i('cap', 'line $i $payload');
      }
      await AppLog.flush();

      final content = (await env.readTextFile(
        '${env.cwd}/${AppLog.filePath}',
      )).valueOrNull!;
      expect(content.length, lessThanOrEqualTo(AppLog.maxFileBytes));
      // The tail survives; the oldest lines were dropped.
      expect(content, contains('line 549'));
      expect(content, isNot(contains('line 0 ')));
    });
  });
}
