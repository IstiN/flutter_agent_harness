import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/power_config.dart';
import 'package:test/test.dart';

/// The `power.sleepPrevention` model (issue #325, ported from
/// oh-my-pi): strict section parse, cumulative levels, and the platform
/// argument builders — pure Dart, no process ever spawned here.
void main() {
  group('parsePowerSection', () {
    test('absent section parses to null (caller defaults to idle)', () {
      expect(parsePowerSection(null), isNull);
      expect(parsePowerSection(<String, Object?>{}), isNull);
    });

    test('parses every documented level', () {
      expect(
        parsePowerSection(const {'sleepPrevention': 'off'}),
        PowerAssertionLevel.off,
      );
      expect(
        parsePowerSection(const {'sleepPrevention': 'idle'}),
        PowerAssertionLevel.idle,
      );
      expect(
        parsePowerSection(const {'sleepPrevention': 'display'}),
        PowerAssertionLevel.display,
      );
      expect(
        parsePowerSection(const {'sleepPrevention': 'system'}),
        PowerAssertionLevel.system,
      );
    });

    test('a bad value throws ConfigException naming the key', () {
      expect(
        () => parsePowerSection(const {'sleepPrevention': 'sometimes'}),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('"power.sleepPrevention" must be off, idle, display or '
                'system'),
          ),
        ),
      );
    });

    test('an unknown member throws ConfigException', () {
      expect(
        () => parsePowerSection(const {'sleepPrevention': 'idle', 'bogus': 1}),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown "power" key: bogus'),
          ),
        ),
      );
    });

    test('a non-map section throws ConfigException', () {
      expect(
        () => parsePowerSection('idle'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('power must be a map'),
          ),
        ),
      );
    });
  });

  group('PowerAssertionLevel', () {
    test('fromValue maps labels and rejects everything else', () {
      for (final level in PowerAssertionLevel.values) {
        expect(PowerAssertionLevel.fromValue(level.value), level);
      }
      expect(PowerAssertionLevel.fromValue('never'), isNull);
      expect(PowerAssertionLevel.fromValue(null), isNull);
    });

    test('toString renders the config label', () {
      expect('${PowerAssertionLevel.display}', 'display');
    });
  });

  group('powerAssertionOptions (cumulative levels)', () {
    test('off asks for no assertion at all', () {
      expect(powerAssertionOptions(PowerAssertionLevel.off), isNull);
    });

    test('idle prevents idle sleep only', () {
      final options = powerAssertionOptions(PowerAssertionLevel.idle)!;
      expect(options.idle, isTrue);
      expect(options.display, isFalse);
      expect(options.system, isFalse);
      expect(options.user, isFalse);
      expect(options.reason, defaultPowerAssertionReason);
    });

    test('display adds the display assertion', () {
      final options = powerAssertionOptions(PowerAssertionLevel.display)!;
      expect(options.idle, isTrue);
      expect(options.display, isTrue);
      expect(options.system, isFalse);
      expect(options.user, isFalse);
    });

    test('system adds system sleep + user activity', () {
      final options = powerAssertionOptions(PowerAssertionLevel.system)!;
      expect(options.idle, isTrue);
      expect(options.display, isTrue);
      expect(options.system, isTrue);
      expect(options.user, isTrue);
    });
  });

  group('caffeinateArguments', () {
    PowerAssertionOptions options(PowerAssertionLevel level) =>
        powerAssertionOptions(level)!;

    test('idle: caffeinate -i -w <pid>', () {
      expect(
        caffeinateArguments(options(PowerAssertionLevel.idle), pid: 4242),
        ['-i', '-w', '4242'],
      );
    });

    test('display: caffeinate -i -d -w <pid>', () {
      expect(
        caffeinateArguments(options(PowerAssertionLevel.display), pid: 7),
        ['-i', '-d', '-w', '7'],
      );
    });

    test('system: caffeinate -i -d -s -u -w <pid>', () {
      expect(
        caffeinateArguments(options(PowerAssertionLevel.system), pid: 1),
        ['-i', '-d', '-s', '-u', '-w', '1'],
      );
    });
  });

  group('systemdInhibitArguments', () {
    test('idle level inhibits idle only, with a pid watchdog', () {
      final args = systemdInhibitArguments(
        powerAssertionOptions(PowerAssertionLevel.idle)!,
        pid: 4242,
      );
      expect(args.first, '--what=idle');
      expect(args, containsAll(['--who=fa', '--why=fa agent session']));
      // The watchdog must reference the fa pid so the assertion dies
      // with the process.
      expect(args.join(' '), contains('kill -0 4242'));
    });

    test('system level also inhibits sleep', () {
      final args = systemdInhibitArguments(
        powerAssertionOptions(PowerAssertionLevel.system)!,
        pid: 9,
      );
      expect(args.first, '--what=idle:sleep');
    });
  });
}
