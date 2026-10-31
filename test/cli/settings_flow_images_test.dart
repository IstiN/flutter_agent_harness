// The images settings flow tests (issue #395 + #1916), split from
// settings_flow_test.dart to keep that file under the repo's 2800-line
// size gate. Same conventions: the registry settings are process-wide
// globals, so every test starts from a fresh boot state.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:yaml/yaml.dart' show YamlMap, loadYaml;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(StreamFunction streamFunction, {String? homeDir}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        homeDir: homeDir,
        sessionRoot: '/sessions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('images settings flow (issue #395)', () {
    // The registry settings are process-wide globals (bin/fah.dart boots
    // them from the section); every test starts from a fresh boot state.
    setUp(() => imageRegistryConfig = const ImageRegistryConfig());
    tearDown(() => imageRegistryConfig = const ImageRegistryConfig());

    Future<void> seed(String text) =>
        env.writeFile('/home/u/.fah/config.yaml', text);

    test(
      'AC1: hub picker row and line-mode summary carry the effective value',
      () async {
        // Boot state (bin/fah.dart publishes the section into the global).
        imageRegistryConfig = const ImageRegistryConfig(
          enabled: false,
          maxPerRequest: 7,
        );
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        io.sendLine('/settings');
        await waitForIt(() => io.out.toString().contains('images:'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(
          output,
          contains('images: off · legacy request shape · cap 7 · ~8MB'),
        );
        final row = cli.settingsHubItems().firstWhere(
          (item) => item.key == 'images',
        );
        expect(row.label, 'Images');
        expect(row.description, 'off · legacy request shape · cap 7 · ~8MB');
        expect(
          cli.settingsPickerHandlerKeysForTest(),
          contains('images'),
          reason: 'a hub row without a handler is a dead menu entry',
        );
        expect(fake.calls, 0);
      },
    );

    test(
      'AC2: toggle and cap round-trip every field; other sections intact',
      () async {
        await seed(
          'provider: openrouter\nmodel: m1\nimages:\n'
          '  registry: true\n  maxPerRequest: 20\nmemory:\n'
          '  projectPath: ./mem\n',
        );
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startImagesFlow();
        await waitForIt(() => io.out.toString().contains('Toggle registry'));
        io.sendLine('1'); // kill switch on → off
        await waitForIt(
          () => io.out.toString().contains('images.registry = false'),
        );
        io.sendLine('2'); // the cap
        await waitForIt(
          () => io.out.toString().contains("per-request cap (empty keeps '20'"),
        );
        io.sendLine('5');
        await waitForIt(
          () => io.out.toString().contains('images.maxPerRequest = 5'),
        );
        io.sendLine('3'); // the byte budget (#1916)
        await waitForIt(
          () => io.out.toString().contains('per-request image budget'),
        );
        io.sendLine('1048576');
        await waitForIt(
          () =>
              io.out.toString().contains('images.maxBytesPerRequest = 1048576'),
        );
        io.sendLine('4'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        // Surgical: everything outside the images block is byte-identical.
        expect(
          written!,
          startsWith('provider: openrouter\nmodel: m1\nimages:'),
        );
        expect(written, endsWith('memory:\n  projectPath: ./mem\n'));
        // The real boot parser re-reads the file.
        final parsed = CliConfig.fromYaml(loadYaml(written) as YamlMap);
        expect(
          parsed.images!.enabled,
          isFalse,
          reason: 'the toggle flipped it',
        );
        expect(parsed.images!.maxPerRequest, 5);
        expect(parsed.images!.maxBytesPerRequest, 1048576);
        // Reload-after-write: the global the request build consults.
        expect(imageRegistryConfig.enabled, isFalse);
        expect(imageRegistryConfig.maxPerRequest, 5);
        expect(imageRegistryConfig.maxBytesPerRequest, 1048576);
        expect(fake.calls, 0);
      },
    );

    test(
      'AC3: the write republishes the live global and names when it lands',
      () async {
        await seed('provider: openrouter\nimages:\n  registry: true\n');
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startImagesFlow();
        await waitForIt(() => io.out.toString().contains('Toggle registry'));
        io.sendLine('1'); // registry off
        await waitForIt(
          () =>
              io.out.toString().contains('(applies to the next request build'),
        );
        io.sendLine('4'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        // The request build consults this global (agent_loop's rewrite) —
        // the change is live without a restart.
        expect(imageRegistryConfig.enabled, isFalse);
        expect(fake.calls, 0);
      },
    );

    test('AC4: an invalid cap shows the parser error, writes nothing; '
        'an empty answer keeps the value', () async {
      const seedText = 'provider: openrouter\nimages:\n  maxPerRequest: 20\n';
      await seed(seedText);
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startImagesFlow();
      await waitForIt(() => io.out.toString().contains('Toggle registry'));
      io.sendLine('2'); // the cap
      await waitForIt(
        () => io.out.toString().contains('per-request cap (empty keeps'),
      );
      io.sendLine('abc'); // invalid → the parser's verbatim message
      await waitForIt(
        () =>
            io.out.toString().contains('not saved:') &&
            io.out.toString().contains(
              '"images.maxPerRequest" must be a positive integer',
            ),
      );
      // An empty answer keeps the current value (no write, no error).
      final promptsBefore = 'per-request cap (empty keeps'
          .allMatches(io.out.toString())
          .length;
      io.sendLine('2');
      await waitForIt(
        () =>
            'per-request cap (empty keeps'
                .allMatches(io.out.toString())
                .length >
            promptsBefore,
      );
      io.sendLine(''); // empty keeps
      io.sendLine('4'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      expect(
        (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull,
        seedText,
        reason: 'nothing may be written',
      );
      expect(imageRegistryConfig.maxPerRequest, 20);
      expect(fake.calls, 0);
    });

    test(
      'E1: absent section offers defaults and writes a fresh block',
      () async {
        await seed('provider: openrouter\nmodel: m1\n');
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(fake.call, homeDir: '/home/u');
        final run = cli.run();

        final flow = cli.startImagesFlow();
        await waitForIt(() => io.out.toString().contains('Toggle registry'));
        // The parser defaults are offered.
        expect(
          io.out.toString(),
          contains('on → off (byte-identical legacy requests)'),
        );
        expect(io.out.toString(), contains('20 unique image(s) per request'));
        io.sendLine('1'); // toggle off → a fresh block lands at the end
        await waitForIt(
          () => io.out.toString().contains('images.registry = false'),
        );
        io.sendLine('4'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written!, startsWith('provider: openrouter\nmodel: m1\n'));
        final parsed = CliConfig.fromYaml(loadYaml(written) as YamlMap);
        expect(parsed.images!.enabled, isFalse);
        expect(parsed.images!.maxPerRequest, 20, reason: 'the parser default');
        expect(fake.calls, 0);
      },
    );

    test('E2: an unreadable config file refuses with a clear error', () async {
      await env.createDir('/home/u/.fah/config.yaml');
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startImagesFlow();
      await waitForIt(() => io.out.toString().contains('Toggle registry'));
      io.sendLine('1'); // the toggle → the write path reads the config
      await waitForIt(
        () =>
            io.out.toString().contains('cannot read /home/u/.fah/config.yaml'),
      );
      io.sendLine('4'); // done
      await flow;
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test('no user config on this host prints and writes nothing', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call); // no homeDir → no user config path
      final run = cli.run();

      final flow = cli.startImagesFlow();
      await waitForIt(() => io.out.toString().contains('Toggle registry'));
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains('no user config on this host'),
      );
      io.sendLine('4'); // done
      await flow;
      io.sendLine('/exit');
      await run;
      expect(fake.calls, 0);
    });

    test('E3: a concurrent images edit survives the write', () async {
      await seed('provider: openrouter\nimages:\n  maxPerRequest: 20\n');
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startImagesFlow();
      await waitForIt(() => io.out.toString().contains('Toggle registry'));
      io.sendLine('2'); // the cap
      await waitForIt(
        () => io.out.toString().contains('per-request cap (empty keeps'),
      );
      // A concurrent edit lands while the prompt sits open.
      await env.writeFile(
        '/home/u/.fah/config.yaml',
        'provider: openrouter\nimages:\n  maxPerRequest: 20\n'
            '  registry: false\n',
      );
      io.sendLine('9');
      await waitForIt(
        () => io.out.toString().contains('images.maxPerRequest = 9'),
      );
      io.sendLine('4'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final written = (await env.readTextFile(
        '/home/u/.fah/config.yaml',
      )).valueOrNull;
      final parsed = CliConfig.fromYaml(loadYaml(written!) as YamlMap);
      expect(parsed.images!.maxPerRequest, 9);
      expect(
        parsed.images!.enabled,
        isFalse,
        reason: 'reload-before-write: the concurrent toggle survives',
      );
      // The republished global carries both fields.
      expect(imageRegistryConfig.maxPerRequest, 9);
      expect(imageRegistryConfig.enabled, isFalse);
      expect(fake.calls, 0);
    });

    test('cancelled at the menu writes nothing', () async {
      const seedText = 'provider: openrouter\n';
      await seed(seedText);
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call, homeDir: '/home/u');
      final run = cli.run();

      final flow = cli.startImagesFlow();
      await waitForIt(() => io.out.toString().contains('Toggle registry'));
      io.interrupt();
      await flow;
      io.sendLine('/exit');
      await run;

      expect(
        (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull,
        seedText,
      );
      expect(fake.calls, 0);
    });
  });
}
