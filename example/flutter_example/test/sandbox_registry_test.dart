import 'package:flutter_agent_example/sandbox_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sandboxCommandsFor (advertised lists)', () {
    test('web advertises qjs + sqlite3 but not node, ssh, or lua', () {
      final names = sandboxCommandsFor(
        SandboxPlatform.web,
      ).map((c) => c.name).toSet();
      expect(names, containsAll(['qjs', 'js', 'sqlite3', 'python3', 'git']));
      expect(names, isNot(contains('node')));
      // Registered on web but always exit 127 — never advertised.
      for (final stub in ['ssh', 'scp', 'sftp', 'lua']) {
        expect(names, isNot(contains(stub)), reason: '$stub on web');
      }
    });

    test('android advertises qjs, sqlite3, ssh and lua but not node', () {
      final names = sandboxCommandsFor(
        SandboxPlatform.android,
      ).map((c) => c.name).toSet();
      expect(
        names,
        containsAll([
          'qjs',
          'js',
          'sqlite3',
          'python3',
          'git',
          'ssh',
          'scp',
          'sftp',
          'lua',
        ]),
      );
      expect(names, isNot(contains('node')));
    });

    test('ios advertises the same shell commands as android', () {
      final names = sandboxCommandsFor(
        SandboxPlatform.ios,
      ).map((c) => c.name).toSet();
      expect(
        names,
        containsAll([
          'qjs',
          'js',
          'sqlite3',
          'python3',
          'git',
          'ssh',
          'scp',
          'sftp',
          'lua',
        ]),
      );
      expect(names, isNot(contains('node')));
    });

    test('desktop has no fixed list (host shell)', () {
      expect(sandboxCommandsFor(SandboxPlatform.desktop), isEmpty);
      expect(sandboxCommandNamesFor(SandboxPlatform.desktop), isEmpty);
    });

    test('every advertised command resolves in the ground-truth name set', () {
      for (final platform in [
        SandboxPlatform.web,
        SandboxPlatform.android,
        SandboxPlatform.ios,
      ]) {
        final names = sandboxCommandNamesFor(platform);
        for (final command in sandboxCommandsFor(platform)) {
          expect(
            names,
            contains(command.name),
            reason: '${command.name} on $platform',
          );
        }
      }
    });

    test('node exists on no platform', () {
      for (final platform in SandboxPlatform.values) {
        expect(
          sandboxCommandNamesFor(platform),
          isNot(contains('node')),
          reason: 'names on $platform',
        );
        expect(
          sandboxCommandsFor(platform).map((c) => c.name),
          isNot(contains('node')),
          reason: 'advertised on $platform',
        );
      }
    });
  });

  group('sandboxCommandNamesFor (ground truth)', () {
    test('web is the MemoryShell set, including the 127 stubs', () {
      expect(sandboxCommandNamesFor(SandboxPlatform.web), webShellCommandNames);
      // The stubs stay registered so `which` still finds them on web.
      expect(webShellCommandNames, containsAll(['ssh', 'scp', 'sftp', 'lua']));
    });

    test(
      'android is the union of coreutils applets, builtins, and modules',
      () {
        expect(sandboxCommandNamesFor(SandboxPlatform.android), {
          ...mobileCoreutilsApplets,
          ...mobileBuiltinCommands,
          ...mobileModuleCommands,
        });
        expect(
          sandboxCommandNamesFor(SandboxPlatform.android),
          containsAll(['ls', 'qjs', 'js', 'lua', 'sqlite3', 'ssh', 'python3']),
        );
      },
    );

    test('ios resolves the same commands as android', () {
      expect(sandboxCommandNamesFor(SandboxPlatform.ios), {
        ...mobileCoreutilsApplets,
        ...mobileBuiltinCommands,
        ...mobileModuleCommands,
      });
      expect(
        sandboxCommandNamesFor(SandboxPlatform.ios),
        containsAll(['ls', 'qjs', 'js', 'lua', 'sqlite3', 'ssh', 'python3']),
      );
    });
  });

  group('formatSandboxCommandSection', () {
    test('web lists the interpreters and the anti-node/anti-apt guidance', () {
      final section = formatSandboxCommandSection(SandboxPlatform.web);
      expect(section, contains('qjs/js'));
      expect(section, contains('NO node'));
      expect(section, contains('apt-get'));
      expect(section, contains('pyodide'));
      expect(section, contains('sql.js'));
      // Web absences are called out explicitly.
      expect(section, contains('CORS'));
      expect(section, contains('ssh/scp/sftp'));
      expect(section, contains('lua'));
      // The compact core line carries the plain POSIX utilities.
      expect(section, contains('core utilities:'));
      expect(section, contains(' ls '));
      // Registered-but-127 stubs must not leak into the core line.
      final coreLine = section
          .split('\n')
          .firstWhere((line) => line.contains('core utilities:'));
      for (final stub in ['ssh', 'scp', 'sftp', 'lua']) {
        expect(coreLine.split(' '), isNot(contains(stub)), reason: stub);
      }
    });

    test('android lists ssh/lua and the anti-node/anti-apt guidance', () {
      final section = formatSandboxCommandSection(SandboxPlatform.android);
      expect(section, contains('ssh/scp/sftp — remote access'));
      expect(section, contains('lua — Lua 5.1 interpreter'));
      expect(section, contains('CPython 3.14'));
      expect(section, contains('qjs/js'));
      expect(section, contains('NO node'));
      expect(section, contains('apt-get'));
      // No browser-only limitations on Android.
      expect(section, isNot(contains('CORS')));
    });

    test('ios lists the same commands as android', () {
      final section = formatSandboxCommandSection(SandboxPlatform.ios);
      expect(section, contains('ssh/scp/sftp — remote access'));
      expect(section, contains('lua — Lua 5.1 interpreter'));
      expect(section, contains('CPython 3.14'));
      expect(section, contains('qjs/js'));
      expect(section, contains('NO node'));
      expect(section, contains('apt-get'));
      expect(section, isNot(contains('CORS')));
    });

    test('desktop describes the host shell instead of a command list', () {
      final section = formatSandboxCommandSection(SandboxPlatform.desktop);
      expect(section, contains('host machine'));
      expect(section, isNot(contains('apt-get')));
    });

    test('consecutive entries with the same summary render merged', () {
      final section = formatSandboxCommandSection(SandboxPlatform.web);
      expect(section, contains('curl/wget — HTTP(S) requests and downloads'));
    });

    test('no unresolved placeholder remains', () {
      for (final platform in SandboxPlatform.values) {
        expect(
          formatSandboxCommandSection(platform),
          isNot(contains('{{')),
          reason: '$platform',
        );
      }
    });
  });
}
