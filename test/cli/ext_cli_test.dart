import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/ext_cli.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Headless `fa ext <verb>` behavior: list/install/remove/update/audit,
/// trust prompting (TOFU), pins, and the startup bootstrap applier.
void main() {
  const projectDir = '/proj';
  const userDir = '/home/u';

  Future<String> okProbe() async => 'quickjs-ng 1.0';

  Future<String> brokenProbe() async =>
      throw ExtEngineUnavailableException('install quickjs-ng (qjs)');

  final io = _FakeIo();
  late MemoryExecutionEnv env;

  setUp(() {
    io.reset();
    io.isInteractive = false;
    env = MemoryExecutionEnv(cwd: projectDir);
  });

  /// Runs `fa ext <args>` against the fixtures.
  Future<int> run(
    List<String> args, {
    _FakeIo? ioOverride,
    http.Client? client,
  }) {
    final cmd = (parseCliArgs(['ext', ...args]) as CliArgs).ext!;
    final commandIo = ioOverride ?? io;
    return runExtCliCommand(
      cmd,
      io: commandIo,
      env: env,
      projectDir: projectDir,
      userDir: userDir,
      client: client,
      engineProbe: okProbe,
    );
  }

  /// Seeds an extension source directory (`/proj/<name>-src`).
  Future<String> seedSource(
    String name, {
    String version = '1.0.0',
    String main = 'export default 1;',
    Map<String, dynamic>? capabilities,
    List<String>? platforms,
    String? dir,
  }) async {
    final root = dir ?? '$projectDir/$name-src';
    await env.writeFile(
      '$root/manifest.json',
      jsonEncode({
        'name': name,
        'version': version,
        'capabilities': ?capabilities,
        'platforms': ?platforms,
      }),
    );
    await env.writeFile('$root/main.js', main);
    return root;
  }

  /// The pinned hash for a freshly seeded source dir (exact content).
  Future<String> pinFor(String name) async => extContentHash({
    'manifest.json': await _text(env, '$projectDir/$name-src/manifest.json'),
    'main.js': await _text(env, '$projectDir/$name-src/main.js'),
  });

  Future<String?> storedSha(String name) async {
    final store = ExtensionStore(
      env: env,
      projectDir: projectDir,
      userDir: userDir,
    );
    return (await store.find(name))?.trust?.contentSha256;
  }

  group('list', () {
    test('shows engine, entries, scope, trust, and platform markers', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      await env.writeFile(
        '$userDir/.fah/js-ext/userly/manifest.json',
        jsonEncode({'name': 'userly', 'version': '0.2.0'}),
      );
      await env.writeFile('$userDir/.fah/js-ext/userly/main.js', 'x');
      await seedSource('webonly', platforms: ['web']);
      await run([
        'install',
        './webonly-src',
        '--trust',
        '--pin',
        await pinFor('webonly'),
      ]);

      final code = await run(['list']);
      expect(code, 0);
      expect(io.err, contains('engine: quickjs-ng 1.0'));
      expect(io.out, contains('demo  project  widget v1.0.0  trusted'));
      expect(io.out, contains('userly  user  widget v0.2.0  untrusted'));
      expect(io.out, contains('webonly  project  widget v1.0.0  trusted'));
      expect(io.out, contains('unsupported here'));
    });

    test('engine-unavailable line still lists entries', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      final cmd = (parseCliArgs(['ext', 'list']) as CliArgs).ext!;
      final code = await runExtCliCommand(
        cmd,
        io: io,
        env: env,
        projectDir: projectDir,
        userDir: userDir,
        engineProbe: brokenProbe,
      );
      expect(code, 0);
      expect(
        io.err,
        contains('engine: unavailable (install quickjs-ng (qjs))'),
      );
      expect(io.out, contains('demo'));
    });

    test('--json emits one machine row per extension', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      io.reset();
      await run(['list', '--json']);
      final rows = [
        for (final line in io.out.trim().split('\n'))
          jsonDecode(line) as Map<String, dynamic>,
      ];
      final demo = rows.singleWhere((r) => r['name'] == 'demo');
      expect(demo['scope'], 'project');
      expect(demo['kind'], 'widget');
      expect(demo['version'], '1.0.0');
      expect(demo['trusted'], isTrue);
      expect(demo['source'], 'local');
      expect(demo['supported'], isTrue);
    });
  });

  group('install', () {
    test('local dir happy path with interactive TOFU y', () async {
      await seedSource('demo');
      io.isInteractive = true;
      io.say('y');
      final code = await run(['install', './demo-src']);
      expect(code, 0);
      expect(io.out, contains('installed demo'));
      final read = await env.readTextFile(
        '$projectDir/.fah/js-ext/demo/manifest.json',
      );
      expect(read.isOk, isTrue);
      expect(io.err, contains('sha256:'));
      expect(io.out, contains('Grant trust? [y/N]'));
    });

    test('local dir interactive TOFU n denies without writing', () async {
      await seedSource('demo');
      io.isInteractive = true;
      io.say('n');
      final code = await run(['install', './demo-src']);
      expect(code, 0);
      expect(io.err, contains('not installed demo: trust required'));
      expect(
        (await env.exists('$projectDir/.fah/js-ext/demo')).valueOrNull,
        isFalse,
      );
    });

    test('interactive denial exits 1 under --strict', () async {
      await seedSource('demo');
      io.isInteractive = true;
      io.say('n');
      final code = await run(['install', './demo-src', '--strict']);
      expect(code, 1);
    });

    test('non-interactive requires --trust and --pin (AC8b)', () async {
      await seedSource('demo');
      expect(await run(['install', './demo-src']), 1);
      expect(io.err, contains('refusing to grant trust non-interactively'));
      io.reset();
      expect(await run(['install', './demo-src', '--trust']), 1);
      io.reset();
      expect(await run(['install', './demo-src', '--pin', 'x' * 64]), 1);
      expect(
        (await env.exists('$projectDir/.fah/js-ext/demo')).valueOrNull,
        isFalse,
      );
    });

    test('non-interactive --trust --pin installs', () async {
      await seedSource('demo');
      final code = await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      expect(code, 0);
      expect(io.out, contains('installed demo'));
    });

    test('pin mismatch rejects loudly and writes nothing', () async {
      await seedSource('demo');
      final code = await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        '0' * 64,
      ]);
      expect(code, 1);
      expect(io.err, contains('pinned hash mismatch'));
      expect(
        (await env.exists('$projectDir/.fah/js-ext/demo')).valueOrNull,
        isFalse,
      );
    });

    test('re-install of identical content is up-to-date', () async {
      await seedSource('demo');
      final pin = await pinFor('demo');
      await run(['install', './demo-src', '--trust', '--pin', pin]);
      io.reset();
      final code = await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        pin,
      ]);
      expect(code, 0);
      expect(io.out, contains('up-to-date demo'));
    });

    test(
      'multiple sources install sequentially; failure keeps going',
      () async {
        await seedSource('good');
        final code = await run([
          'install',
          './missing-src',
          './good-src',
          '--trust',
          '--pin',
          await pinFor('good'),
        ]);
        expect(code, 1);
        expect(io.err, contains('install ./missing-src failed:'));
        expect(io.out, contains('installed good'));
      },
    );

    test('bare id installs from the catalog via the injected client', () async {
      final fixture = _catalogFixture();
      final client = MockClient((request) async {
        if (request.url.path.endsWith('catalog.json')) {
          return http.Response.bytes(fixture.catalogBytes, 200);
        }
        if (request.url.path.endsWith('catdemo-1.0.0.zip')) {
          return http.Response.bytes(fixture.zipBytes, 200);
        }
        return http.Response('nope', 404);
      });
      final code = await run([
        'install',
        'catdemo',
        '--trust',
        '--pin',
        fixture.contentPin,
      ], client: client);
      expect(code, 0);
      expect(io.out, contains('installed catdemo'));
      final read = await env.readTextFile(
        '$projectDir/.fah/js-ext/catdemo/manifest.json',
      );
      expect(read.isOk, isTrue);
    });
  });

  group('bundled install', () {
    test('--bundled [name] seeds the named bundled extension', () async {
      final code = await run(['install', '--bundled', 'crap-guard']);
      expect(code, 0);
      expect(io.out, contains('installed crap-guard'));
      expect(
        (await env.exists(
          '$projectDir/.fah/js-ext/crap-guard/main.js',
        )).valueOrNull,
        isTrue,
      );
    });

    test('bare --bundled installs every bundled extension', () async {
      final code = await run(['install', '--bundled']);
      expect(code, 0);
      expect(io.out, contains('installed crap-guard'));
    });

    test('unknown bundled name fails loud', () async {
      final code = await run(['install', '--bundled', 'nope']);
      expect(code, 1);
      expect(io.err, contains('unknown bundled extension: nope'));
    });
  });

  group('remove', () {
    test('removes an installed extension', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      final code = await run(['remove', 'demo']);
      expect(code, 0);
      expect(io.out, contains('removed demo'));
      expect(
        (await env.exists('$projectDir/.fah/js-ext/demo')).valueOrNull,
        isFalse,
      );
    });

    test('missing extension exits 1', () async {
      expect(await run(['remove', 'ghost']), 1);
      expect(io.err, contains('ext not found: ghost'));
    });
  });

  group('update', () {
    test('hash-only change auto-applies headless', () async {
      final src = await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      await env.writeFile('$src/main.js', 'export default 2;');
      io.reset();
      final code = await run(['update', 'demo']);
      expect(code, 0);
      expect(io.out, contains('updated demo'));
      expect(
        await storedSha('demo'),
        extContentHash({
          'manifest.json': await _text(env, '$src/manifest.json'),
          'main.js': 'export default 2;',
        }),
      );
    });

    test('capability change headless fails loud and keeps the grant', () async {
      final src = await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      final oldSha = await storedSha('demo');
      await env.writeFile(
        '$src/manifest.json',
        jsonEncode({
          'name': 'demo',
          'version': '1.1.0',
          'capabilities': {'network': true},
        }),
      );
      io.reset();
      final code = await run(['update']);
      expect(code, 1);
      expect(io.err, contains('capabilities changed'));
      expect(await storedSha('demo'), oldSha);
    });

    test('capability change interactively re-prompts and re-grants', () async {
      final src = await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      await env.writeFile(
        '$src/manifest.json',
        jsonEncode({
          'name': 'demo',
          'version': '1.1.0',
          'capabilities': {'network': true},
        }),
      );
      io.reset();
      io.isInteractive = true;
      io.say('y');
      final code = await run(['update', 'demo']);
      expect(code, 0);
      expect(io.out, contains('updated demo'));
      expect(io.err, contains('network: make network requests'));
    });

    test('up-to-date and unknown names behave', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      io.reset();
      expect(await run(['update', 'demo']), 0);
      expect(io.out, contains('up-to-date demo'));
      expect(await run(['update', 'ghost']), 1);
      expect(io.err, contains('ext not found: ghost'));
    });
  });

  group('audit', () {
    test('prints the trust record and untrusted tombstones', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      await env.writeFile(
        '$userDir/.fah/js-ext/tomb/manifest.json',
        jsonEncode({'name': 'tomb', 'version': '0.1.0'}),
      );
      await env.writeFile('$userDir/.fah/js-ext/tomb/main.js', 'x');

      final code = await run(['audit']);
      expect(code, 0);
      final out = io.out;
      expect(out, contains('demo'));
      expect(out, contains('source: local ($projectDir/demo-src)'));
      expect(out, contains('sha256: '));
      expect(out, contains('granted: 20'));
      expect(out, contains('tomb: untrusted'));
    });

    test('--json emits one row per extension', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      io.reset();
      await run(['audit', '--json']);
      final rows = [
        for (final line in io.out.trim().split('\n'))
          jsonDecode(line) as Map<String, dynamic>,
      ];
      final demo = rows.singleWhere((r) => r['name'] == 'demo');
      expect(demo['trusted'], isTrue);
      expect(demo['source'], 'local');
      expect(demo['capabilities'], isA<Map<String, dynamic>>());
    });

    test('unknown name exits 1', () async {
      expect(await run(['audit', 'ghost']), 1);
      expect(io.err, contains('ext not found: ghost'));
    });
  });

  group('enable/disable', () {
    test('are REPL-only', () async {
      expect(await run(['enable', 'demo']), 1);
      expect(io.err, contains('REPL-only'));
      io.reset();
      expect(await run(['disable', 'demo']), 1);
      expect(io.err, contains('REPL-only'));
    });
  });

  group('bootstrap', () {
    Future<void> writeBootstrap(String base, String yaml) =>
        env.writeFile('$base/.fah/bootstrap.yaml', yaml);

    Future<bool> markerPresent() async {
      final listed = await env.listDir('$projectDir/.fah/js-ext');
      return listed.valueOrNull!.any(
        (entry) => entry.path.contains('.bootstrap-applied-'),
      );
    }

    test('applies a local source interactively, then is idempotent', () async {
      await seedSource('demo');
      await writeBootstrap(projectDir, 'extensions:\n  - source: ./demo-src\n');
      io.isInteractive = true;
      io.say('y');
      await applyBootstrapIfPresent(
        io: io,
        env: env,
        projectDir: projectDir,
        userDir: userDir,
      );
      expect(io.err, contains('ext demo installed'));
      expect(await markerPresent(), isTrue);

      io.reset();
      await applyBootstrapIfPresent(
        io: io,
        env: env,
        projectDir: projectDir,
        userDir: userDir,
      );
      expect(io.err, isEmpty, reason: 'marker must make re-runs silent');
    });

    test('pre-trusted extension is up-to-date headless', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      await writeBootstrap(projectDir, 'extensions:\n  - source: ./demo-src\n');
      await applyBootstrapIfPresent(
        io: io,
        env: env,
        projectDir: projectDir,
        userDir: userDir,
      );
      expect(io.err, contains('ext demo up-to-date'));
    });

    test('E15: unreachable entry is a named line, session proceeds', () async {
      await writeBootstrap(
        projectDir,
        'extensions:\n  - source: ./missing-src\n',
      );
      await applyBootstrapIfPresent(
        io: io,
        env: env,
        projectDir: projectDir,
        userDir: userDir,
      );
      expect(io.err, contains('FAILED'));
      expect(await markerPresent(), isTrue);
    });

    test('E15 strict rethrows', () async {
      await writeBootstrap(
        projectDir,
        'extensions:\n  - source: ./missing-src\n',
      );
      await expectLater(
        applyBootstrapIfPresent(
          io: io,
          env: env,
          projectDir: projectDir,
          userDir: userDir,
          strict: true,
        ),
        throwsA(isA<Object>()),
      );
    });

    test('E16: project scope wins; the user loser is reported once', () async {
      await seedSource('demo');
      await run([
        'install',
        './demo-src',
        '--trust',
        '--pin',
        await pinFor('demo'),
      ]);
      await writeBootstrap(projectDir, 'extensions:\n  - source: ./demo-src\n');
      await seedSource(
        'demo',
        main: 'export default "user";',
        dir: '$userDir/demo-src',
      );
      await writeBootstrap(
        userDir,
        'extensions:\n  - source: /home/u/demo-src\n',
      );
      await applyBootstrapIfPresent(
        io: io,
        env: env,
        projectDir: projectDir,
        userDir: userDir,
      );
      expect(io.err, contains('E16'));
      expect(io.err, contains('skipped'));
    });

    test('config change re-applies (new marker hash)', () async {
      await seedSource('demo');
      await writeBootstrap(projectDir, 'extensions:\n  - source: ./demo-src\n');
      io.isInteractive = true;
      io.say('y');
      await applyBootstrapIfPresent(
        io: io,
        env: env,
        projectDir: projectDir,
        userDir: userDir,
      );
      await env.writeFile(
        '$projectDir/.fah/bootstrap.yaml',
        'extensions:\n  - source: ./demo-src\n  - source: ./missing-src\n',
      );
      io.reset();
      io.isInteractive = true;
      io.say('y');
      await applyBootstrapIfPresent(
        io: io,
        env: env,
        projectDir: projectDir,
        userDir: userDir,
      );
      expect(io.err, contains('FAILED'));
    });
  });
}

Future<String> _text(MemoryExecutionEnv env, String path) async =>
    (await env.readTextFile(path)).valueOrNull!;

/// In-memory [CliIO] with SEPARATE stdout ([out]) / stderr ([err]) buffers,
/// mirroring the headless [_TerminalCliIO] channel split.
class _FakeIo implements CliIO {
  StreamController<String> _controller = StreamController<String>();
  String out = '';
  String err = '';

  @override
  bool isInteractive = false;

  @override
  int columns = 80;

  @override
  int rows = 24;

  void reset() {
    out = '';
    err = '';
    _controller = StreamController<String>();
  }

  /// Queues an input line, buffered until the command listens.
  void say(String line) => _controller.add(line);

  @override
  Stream<String> get lines => _controller.stream;

  @override
  Stream<void> get interrupts => const Stream<void>.empty();

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();

  @override
  bool get supportsRawMode => false;
  @override
  void write(String text) => out += text;

  @override
  void writeln(String text) => err += '$text\n';
}

/// Builds a sealed v2 catalog with one CLI-extension entry; [contentPin] is
/// the `extContentHash` of the extracted files (what `--pin` must match).
({List<int> catalogBytes, List<int> zipBytes, String contentPin})
_catalogFixture() {
  const manifest =
      '{"name":"catdemo","kind":"cli-extension","version":"1.0.0"}';
  const main = 'export default 1;';
  final manifestBytes = utf8.encode(manifest);
  final mainBytes = utf8.encode(main);
  final archive = Archive()
    ..addFile(
      ArchiveFile('catdemo/manifest.json', manifestBytes.length, manifestBytes),
    )
    ..addFile(ArchiveFile('catdemo/main.js', mainBytes.length, mainBytes));
  final zip = Uint8List.fromList(ZipEncoder().encode(archive));
  final catalog = jsonEncode({
    'schemaVersion': 2,
    'extensions': [
      {
        'id': 'catdemo',
        'version': '1.0.0',
        'kind': 'cli-extension',
        'zipFile': 'catdemo-1.0.0.zip',
        'zipSha256': crypto.sha256.convert(zip).toString(),
      },
    ],
  });
  return (
    catalogBytes: utf8.encode(catalog),
    zipBytes: zip,
    contentPin: extContentHash({'manifest.json': manifest, 'main.js': main}),
  );
}
