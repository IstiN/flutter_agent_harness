// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/cli/output_config.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('parseOutputSection', () {
    test('an absent section is valid', () {
      expect(() => parseOutputSection(null), returnsNormally);
    });

    test('streamThinking true and false both parse', () {
      expect(
        () => parseOutputSection(loadYaml('streamThinking: true')),
        returnsNormally,
      );
      expect(
        () => parseOutputSection(loadYaml('streamThinking: false')),
        returnsNormally,
      );
    });

    test('a non-map section throws ConfigException', () {
      expect(
        () => parseOutputSection(loadYaml('- a')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('output must be a map'),
          ),
        ),
      );
    });

    test('an unknown key throws ConfigException (a typo never silently '
        'keeps the default)', () {
      expect(
        () => parseOutputSection(loadYaml('streamThnking: true')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown "output" key: streamThnking'),
          ),
        ),
      );
    });

    test('a non-boolean streamThinking throws ConfigException', () {
      expect(
        () => parseOutputSection(loadYaml('streamThinking: "yes"')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('"output.streamThinking" must be a boolean'),
          ),
        ),
      );
    });
  });

  group('outputStreamThinkingValue', () {
    test('true only when explicitly set to true', () {
      expect(
        outputStreamThinkingValue(loadYaml('streamThinking: true')),
        isTrue,
      );
    });

    test('false when the key is absent, false, or the node is not a map', () {
      expect(outputStreamThinkingValue(null), isFalse);
      expect(
        outputStreamThinkingValue(loadYaml('streamThinking: false')),
        isFalse,
      );
      expect(outputStreamThinkingValue('not a map'), isFalse);
    });
  });
}
