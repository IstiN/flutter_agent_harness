// Issue #2117 — the logging layer units: level parsing, the five-source
// precedence chain, per-sink gating (incl. the keys=debug alias floor),
// pattern rendering, and the strict `logging:` config section.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

LogEvent _event({String message = 'hello', bool errorLevel = false}) =>
    LogEvent(
      time: DateTime(2026, 11, 13, 14, 3, 22, 105),
      elapsed: const Duration(milliseconds: 12345),
      sid: 'abc12345',
      level: errorLevel ? LogLevel.error : LogLevel.info,
      category: LogCategory.tool,
      message: message,
    );

void main() {
  group('LogLevel.parse', () {
    test('accepts the six keywords, case-insensitive, trimmed', () {
      expect(LogLevel.parse('off', label: 'x'), LogLevel.off);
      expect(LogLevel.parse('ERROR', label: 'x'), LogLevel.error);
      expect(LogLevel.parse(' warn ', label: 'x'), LogLevel.warn);
      expect(LogLevel.parse('Info', label: 'x'), LogLevel.info);
      expect(LogLevel.parse('debug', label: 'x'), LogLevel.debug);
      expect(LogLevel.parse('trace', label: 'x'), LogLevel.trace);
    });

    test('invalid input is LOUD — never a silent fallthrough', () {
      expect(
        () => LogLevel.parse('verbose', label: 'FA_LOG_LEVEL'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('FA_LOG_LEVEL'),
          ),
        ),
      );
      expect(
        () => LogLevel.parse('', label: '/log'),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('resolveLogSettings precedence (issue #2117 AC1)', () {
    test('defaults: interactive warn, file debug, nothing explicit', () {
      final s = resolveLogSettings();
      expect(s.consoleLevel, LogLevel.warn);
      expect(s.consoleExplicit, isFalse);
      expect(s.fileLevel, LogLevel.debug);
      expect(s.format, isNull);
      expect(s.timeFormat, defaultLogTimeFormat);
      expect(s.keysFloor, isFalse);
    });

    test('flag > env > project > user', () {
      final s = resolveLogSettings(
        flagLevel: LogLevel.error,
        envLevel: 'trace',
        project: const LoggingConfig(console: LogLevel.debug),
        user: const LoggingConfig(console: LogLevel.info),
      );
      expect(s.consoleLevel, LogLevel.error);
      expect(s.consoleExplicit, isTrue);
    });

    test('env > project > user', () {
      final s = resolveLogSettings(
        envLevel: 'trace',
        project: const LoggingConfig(console: LogLevel.debug),
        user: const LoggingConfig(console: LogLevel.info),
      );
      expect(s.consoleLevel, LogLevel.trace);
      expect(s.consoleExplicit, isTrue);
    });

    test('project > user > default; config alone is NOT explicit', () {
      final s = resolveLogSettings(
        project: const LoggingConfig(console: LogLevel.error),
        user: const LoggingConfig(console: LogLevel.info),
      );
      expect(s.consoleLevel, LogLevel.error);
      expect(
        s.consoleExplicit,
        isFalse,
        reason: 'a config level never filters headless stdout',
      );

      final s2 = resolveLogSettings(
        user: const LoggingConfig(console: LogLevel.debug),
      );
      expect(s2.consoleLevel, LogLevel.debug);
      expect(s2.consoleExplicit, isFalse);
    });

    test('blank FA_LOG_LEVEL keeps the chain', () {
      final s = resolveLogSettings(envLevel: '   ');
      expect(s.consoleLevel, LogLevel.warn);
      expect(s.consoleExplicit, isFalse);
    });

    test('invalid FA_LOG_LEVEL throws ConfigException naming the var', () {
      expect(
        () => resolveLogSettings(envLevel: 'loud'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('FA_LOG_LEVEL'),
          ),
        ),
      );
    });

    test('file level resolves independently; format+timeFormat chain', () {
      final s = resolveLogSettings(
        project: const LoggingConfig(
          file: LogLevel.off,
          format: '{time} {msg}',
          timeFormat: 'mm:ss',
        ),
        user: const LoggingConfig(
          file: LogLevel.trace,
          format: 'u {msg}',
          timeFormat: 'HH',
        ),
      );
      expect(s.fileLevel, LogLevel.off, reason: 'project wins wholesale');
      expect(s.format?.template, '{time} {msg}');
      expect(s.timeFormat, 'mm:ss');

      final s2 = resolveLogSettings(
        user: const LoggingConfig(file: LogLevel.trace),
      );
      expect(s2.fileLevel, LogLevel.trace);
    });

    test('--debug-secrets/FA_DEBUG_KEYS map to the keys=debug floor', () {
      final s = resolveLogSettings(debugKeys: true);
      expect(s.keysFloor, isTrue);
    });
  });

  group('per-sink gating (issue #2117 AC1)', () {
    const warnConsole = ResolvedLogSettings();

    /// The console gate's pure half (the live/headless wrapper lives on
    /// [AgentCli]): the same shared core both sinks ride.
    bool consolePasses(ResolvedLogSettings s, LogLevel l, LogCategory c) =>
        logLinePasses(s.consoleLevel, l, c, keysFloor: s.keysFloor);

    test('console warn passes error/warn, hides info/debug/trace', () {
      expect(
        consolePasses(warnConsole, LogLevel.error, LogCategory.lifecycle),
        isTrue,
      );
      expect(
        consolePasses(warnConsole, LogLevel.warn, LogCategory.lifecycle),
        isTrue,
      );
      expect(
        consolePasses(warnConsole, LogLevel.info, LogCategory.lifecycle),
        isFalse,
      );
      expect(
        consolePasses(warnConsole, LogLevel.debug, LogCategory.tool),
        isFalse,
      );
      expect(
        consolePasses(warnConsole, LogLevel.trace, LogCategory.provider),
        isFalse,
      );
    });

    test('sinks filter independently', () {
      expect(
        warnConsole.filePasses(LogLevel.info, LogCategory.lifecycle),
        isTrue,
        reason: 'fa.log default debug keeps every migrated info line',
      );
      expect(warnConsole.filePasses(LogLevel.debug, LogCategory.tool), isTrue);
      expect(
        warnConsole.filePasses(LogLevel.trace, LogCategory.provider),
        isFalse,
      );

      const loud = ResolvedLogSettings(fileLevel: LogLevel.trace);
      expect(loud.filePasses(LogLevel.trace, LogCategory.provider), isTrue);
      expect(
        consolePasses(loud, LogLevel.info, LogCategory.lifecycle),
        isFalse,
      );
    });

    test('file off silences fa.log; console off silences the console', () {
      const offFile = ResolvedLogSettings(fileLevel: LogLevel.off);
      expect(
        offFile.filePasses(LogLevel.error, LogCategory.lifecycle),
        isFalse,
      );
      const offConsole = ResolvedLogSettings(consoleLevel: LogLevel.off);
      expect(
        consolePasses(offConsole, LogLevel.error, LogCategory.lifecycle),
        isFalse,
      );
    });

    test('the keys floor lifts keys-category lines to debug, never past '
        'it, and never resurrects off', () {
      const floored = ResolvedLogSettings(keysFloor: true);
      expect(consolePasses(floored, LogLevel.debug, LogCategory.keys), isTrue);
      expect(
        consolePasses(floored, LogLevel.debug, LogCategory.lifecycle),
        isFalse,
        reason: 'the floor is keys-scoped',
      );
      expect(consolePasses(floored, LogLevel.trace, LogCategory.keys), isFalse);
      const off = ResolvedLogSettings(
        consoleLevel: LogLevel.off,
        keysFloor: true,
      );
      expect(
        consolePasses(off, LogLevel.error, LogCategory.keys),
        isFalse,
        reason: 'off stays off',
      );
    });
  });

  group('pattern rendering (issue #2117 AC2)', () {
    test('every placeholder renders', () {
      final line = const LogPattern(
        '{time} {elapsed} {sid} [{level}/{cat}] '
        '{msg}',
      ).render(_event());
      expect(line, '14:03:22.105 12.345s abc12345 [info/tool] hello');
    });

    test('a custom timeFormat rides the render', () {
      final line = const LogPattern(
        '{time} {msg}',
      ).render(_event(), timeFormat: 'HH:mm:ss');
      expect(line, '14:03:22 hello');
    });

    test('unknown placeholders stay literal', () {
      final line = const LogPattern('{msgg} {msg}').render(_event());
      expect(line, '{msgg} hello');
    });

    test('time tokens pad; unsupported tokens pass through', () {
      expect(
        formatLogTime(DateTime(2026, 1, 2, 3, 4, 5, 6), 'HH:mm:ss.SSS'),
        '03:04:05.006',
      );
      expect(formatLogTime(DateTime(2026), 'week HH'), 'week 00');
    });

    test('error level renders its own tag', () {
      final line = const LogPattern(
        '{level}: {msg}',
      ).render(_event(errorLevel: true));
      expect(line, 'error: hello');
    });
  });

  group('parseLoggingSection + CliConfig round-trip', () {
    LoggingConfig? parse(String yaml) => parseLoggingSection(
      (loadYaml(yaml) as YamlMap)['logging'],
      label: 'test',
    );

    test('parses console/file/format/timeFormat', () {
      final c = parse(
        'logging:\n'
        '  console: info\n'
        '  file: trace\n'
        '  format: "{time} {level} {msg}"\n'
        '  timeFormat: "HH:mm:ss"\n',
      );
      expect(c?.console, LogLevel.info);
      expect(c?.file, LogLevel.trace);
      expect(c?.format, '{time} {level} {msg}');
      expect(c?.timeFormat, 'HH:mm:ss');
    });

    test('unknown key throws; bad level throws; non-map throws', () {
      expect(
        () => parse('logging:\n  bogus: 1\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown "logging" key: bogus'),
          ),
        ),
      );
      expect(
        () => parse('logging:\n  console: loud\n'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseLoggingSection('nope', label: 'test'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('logging must be a map'),
          ),
        ),
      );
      expect(
        () => parse('logging:\n  format: 3\n'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('null node parses as null', () {
      expect(parseLoggingSection(null, label: 'test'), isNull);
    });

    test('a blank format/timeFormat is UNSET, never an empty pattern '
        '(issue #2117 review)', () {
      final c = parse('logging:\n  format: ""\n  timeFormat: "  "\n');
      expect(c?.format, isNull, reason: 'empty would render blank lines');
      expect(c?.timeFormat, isNull);
    });

    test(
      'CliConfig round-trips a hand-written section through saveCliConfig',
      () {
        final yaml =
            'logging:\n  console: info\n  file: trace\n  format: \'{msg}\'\n';
        final config = CliConfig.fromYaml(loadYaml(yaml) as YamlMap);
        expect(config.logging?.console, LogLevel.info);
        final rewritten = config.toYaml();
        final reloaded = CliConfig.fromYaml(loadYaml(rewritten) as YamlMap);
        expect(reloaded.logging?.console, LogLevel.info);
        expect(reloaded.logging?.file, LogLevel.trace);
        expect(reloaded.logging?.format, '{msg}');
      },
    );

    test("an apostrophe in the format survives the save (issue #2117 "
        "review — ' doubled, never corrupting the yaml)", () {
      const format = "it's {msg}";
      final config = CliConfig(
        logging: LoggingConfig(format: format, timeFormat: "HH:mm"),
      );
      final reloaded = CliConfig.fromYaml(loadYaml(config.toYaml()) as YamlMap);
      expect(reloaded.logging?.format, format);
      expect(reloaded.logging?.timeFormat, 'HH:mm');
    });
  });

  group('loadProjectLoggingSection', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fa_logging_cfg_');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    void writeProjectConfig(String content) {
      File('${tmp.path}/.fah/config.yaml')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }

    test('missing project file loads as null', () {
      expect(loadProjectLoggingSection(tmp.path), isNull);
    });

    test('parses the project section', () {
      writeProjectConfig('logging:\n  console: debug\n  file: info\n');
      final loaded = loadProjectLoggingSection(tmp.path);
      expect(loaded?.console, LogLevel.debug);
      expect(loaded?.file, LogLevel.info);
    });

    test('file without a logging section is null', () {
      writeProjectConfig('provider: anthropic\n');
      expect(loadProjectLoggingSection(tmp.path), isNull);
    });

    test('invalid section throws loudly (strict, like the user config)', () {
      writeProjectConfig('logging:\n  bogus: 1\n');
      expect(
        () => loadProjectLoggingSection(tmp.path),
        throwsA(isA<ConfigException>()),
      );
    });

    test('corrupt yaml loads as null', () {
      writeProjectConfig('not yaml: [unclosed');
      expect(loadProjectLoggingSection(tmp.path), isNull);
    });
  });
}
