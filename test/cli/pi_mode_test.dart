// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/cli/pi_mode.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/tools/availability.dart';
import 'package:test/test.dart';

void main() {
  group('resolveHarnessMode', () {
    test('the --pi flag wins over everything (AC3: flag > env > config)', () {
      expect(
        resolveHarnessMode(
          flag: true,
          env: {'FA_PI_MODE': '0'},
          configMode: 'default',
        ),
        'pi',
      );
    });

    test('a truthy FA_PI_MODE env activates pi without the flag', () {
      expect(resolveHarnessMode(env: {'FA_PI_MODE': '1'}), 'pi');
      expect(resolveHarnessMode(env: {'FA_PI_MODE': 'YES'}), 'pi');
    });

    test('a falsy FA_PI_MODE falls through to the config value', () {
      expect(
        resolveHarnessMode(env: {'FA_PI_MODE': '0'}, configMode: 'pi'),
        'pi',
      );
      expect(
        resolveHarnessMode(env: {'FA_PI_MODE': '0'}, configMode: 'default'),
        isNull,
      );
    });

    test('config agent.mode: pi activates, default does not', () {
      expect(resolveHarnessMode(configMode: 'pi'), 'pi');
      expect(resolveHarnessMode(configMode: 'default'), isNull);
    });

    test('nothing set resolves to the legacy default mode (null)', () {
      expect(resolveHarnessMode(), isNull);
      expect(resolveHarnessMode(env: {}), isNull);
    });

    test('an unknown config value throws ConfigException naming the value '
        'and the allowed set — a typo must never boot a benchmark run', () {
      expect(
        () => resolveHarnessMode(configMode: 'p1'),
        throwsA(
          isA<ConfigException>()
              .having(
                (e) => e.message,
                'message',
                contains('unknown "agent.mode" value: p1'),
              )
              .having((e) => e.message, 'allowed set', contains('default|pi')),
        ),
      );
    });
  });

  group('isTruthyEnvValue', () {
    test('accepts the repo-wide truthy set, case-insensitive and trimmed', () {
      for (final v in ['1', 'true', 'yes', 'on', 'TRUE', ' On ', 'Yes']) {
        expect(isTruthyEnvValue(v), isTrue, reason: '$v should be truthy');
      }
    });

    test('rejects everything else, including 0/false/empty/null', () {
      for (final v in ['0', 'false', 'no', 'off', '', '  ', null, '2']) {
        expect(isTruthyEnvValue(v), isFalse, reason: '$v should be falsy');
      }
    });
  });

  group('piToolsOverride', () {
    test(
      'pins every known tool: on exactly for the pi surface, off otherwise',
      () {
        final override = piToolsOverride();
        // Invariant: the pi surface is a subset of the known tool ids — the
        // override cannot grant an unknown tool.
        expect(override.tools.keys.toSet(), knownToolIds.toSet());
        for (final id in knownToolIds) {
          expect(
            override.tools[id],
            piToolIds.contains(id),
            reason: 'tool "$id" availability must equal piToolIds membership',
          );
        }
      },
    );

    test('the pi surface is exactly read, write, edit, bash (issue #679)', () {
      expect(piToolIds, {'read', 'write', 'edit', 'bash'});
      for (final id in piToolIds) {
        expect(knownToolIds, contains(id));
      }
    });
  });
}
