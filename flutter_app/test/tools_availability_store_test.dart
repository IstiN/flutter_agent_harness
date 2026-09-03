// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/tools_availability_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ToolsAvailabilityStore', () {
    test('missing file loads as null (never configured)', () async {
      final env = MemoryExecutionEnv();
      expect(await ToolsAvailabilityStore(env).load(), isNull);
    });

    test('corrupt file loads as null instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/tools_availability.json', '{not json');
      expect(await ToolsAvailabilityStore(env).load(), isNull);
    });

    test('a wrong schema version loads as null', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/tools_availability.json',
        jsonEncode({
          'version': 99,
          'tools': {'bash': false},
        }),
      );
      expect(await ToolsAvailabilityStore(env).load(), isNull);
    });

    test('a config round-trips through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final store = ToolsAvailabilityStore(env);
      final config = ToolsConfig(
        tools: {'bash': false, 'web_search': false, 'memory': true},
      );
      await store.save(config);

      expect((await store.load())?.tools, config.tools);
    });

    test('an empty config round-trips as an empty tools map', () async {
      final env = MemoryExecutionEnv();
      final store = ToolsAvailabilityStore(env);
      await store.save(const ToolsConfig());

      expect((await store.load())?.tools, isEmpty);
    });

    test('the stored envelope is the ToolsConfig interchange format', () async {
      final env = MemoryExecutionEnv();
      final config = ToolsConfig(
        tools: {'bash': false, 'mcp': false, 'mcp:files': true},
      );
      await ToolsAvailabilityStore(env).save(config);

      final text = (await env.readTextFile(
        '${env.cwd}/tools_availability.json',
      )).valueOrNull!;
      // The CLI parses the exact same envelope with the core parser.
      expect(ToolsConfig.fromJson(jsonDecode(text)).tools, config.tools);
    });
  });
}
