/// The interactive `/dap` slash flow: with the host's pickOption/askLine
/// callbacks present, bare `/dap` opens a guided menu (status / connect /
/// master secret / about) instead of dumping a raw error; text args keep
/// the scriptable behavior.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';
import '../hub/fake_hub.dart';

class _CapturingIo implements PluginIO {
  final lines = <String>[];

  @override
  void write(String text) => lines.add(text);

  @override
  void writeln(String text) => lines.add(text);

  String get text => lines.join('\n');
}

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-dap-flow-');
  });

  tearDown(() async {
    if (await tempHome.exists()) tempHome.deleteSync(recursive: true);
  });

  /// Registers the host and returns (slashHandler, io, environment).
  (SlashCommand, _CapturingIo, Map<String, String>) registerHost({
    PluginPickOption? pickOption,
    PluginAskLine? askLine,
    Map<String, String>? environment,
    Map<String, dynamic> config = const {},
  }) {
    final env = environment ?? <String, String>{};
    final host = HubPluginHost(
      hub.HubPlugin(environment: env),
      environment: env,
      home: tempHome.path,
    );
    final io = _CapturingIo();
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: '/work'),
      io: io,
      config: config,
      pickOption: pickOption,
      askLine: askLine,
    );
    host.register(context);
    final slash = context.slashCommands['/dap'];
    expect(slash, isNotNull, reason: '/dap stays unconditionally registered');
    return (slash!, io, env);
  }

  test('the slash registration carries a menu hint', () {
    final host = HubPluginHost(
      hub.HubPlugin(environment: const {}),
      environment: const {},
      home: tempHome.path,
    );
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: '/work'),
      io: _CapturingIo(),
    );
    host.register(context);
    expect(context.slashCommandDescriptions['/dap'], isNotEmpty);
  });

  test('bare /dap opens the menu: status, connect, secret, about', () async {
    String? seenTitle;
    List<PluginMenuOption>? seenOptions;
    final (slash, io, _) = registerHost(
      pickOption: (title, options, {initialKey}) async {
        seenTitle = title;
        seenOptions = options;
        return null; // cancel
      },
    );
    await slash([]);
    expect(seenTitle, isNotNull);
    expect(seenTitle, contains('DAP'));
    final keys = seenOptions!.map((o) => o.$1).toList();
    expect(keys, containsAll(['status', 'connect', 'secret', 'about']));
    // Every option explains itself (the "what is this" hint).
    for (final option in seenOptions!) {
      expect(option.$3, isNotEmpty, reason: option.$1);
    }
    expect(io.text, isNot(contains('Bad state')));
  });

  test(
    'status with no master secret prints a friendly hint, not Bad state',
    () async {
      final (slash, io, _) = registerHost(
        pickOption: (title, options, {initialKey}) async => 'status',
      );
      await slash([]);
      expect(io.text, contains('master secret'));
      expect(io.text, isNot(contains('Bad state')));
    },
  );

  test('about prints the DAP explainer', () async {
    final (slash, io, _) = registerHost(
      pickOption: (title, options, {initialKey}) async => 'about',
    );
    await slash([]);
    expect(io.text, contains('end-to-end'));
    expect(io.text, contains('DAP_MASTER_SECRET'));
  });

  test('secret asks masked input and enables DAP for the session', () async {
    final fakeHub = FakeHub();
    await fakeHub.start();
    addTearDown(fakeHub.stop);
    var askedSecret = false;
    final (slash, io, env) = registerHost(
      config: {'url': fakeHub.url.toString(), 'name': 'flow'},
      pickOption: (title, options, {initialKey}) async => 'secret',
      askLine: (question, {secret = false}) async {
        askedSecret = secret;
        return 'test-master-secret';
      },
    );
    await slash([]);
    expect(askedSecret, isTrue, reason: 'the master secret prompt masks');
    expect(env[hub.envMasterSecret], 'test-master-secret');
    // The zero-config start dialed the configured hub and connected.
    await fakeHub.waitForHellos(1);
    expect(io.text, contains('master secret set'));
    expect(io.text, contains('connected'));
    expect(io.text, isNot(contains('Bad state')));
  });

  test('connect asks for the host and dials it', () async {
    final bootHub = FakeHub();
    await bootHub.start();
    addTearDown(bootHub.stop);
    final targetHub = FakeHub();
    await targetHub.start();
    addTearDown(targetHub.stop);
    final questions = <String>[];
    final (slash, io, _) = registerHost(
      environment: {hub.envMasterSecret: 'x'},
      config: {'url': bootHub.url.toString(), 'name': 'flow'},
      pickOption: (title, options, {initialKey}) async => 'connect',
      askLine: (question, {secret = false}) async {
        questions.add(question);
        return questions.length == 1 ? targetHub.url.toString() : '';
      },
    );
    await slash([]);
    expect(questions, isNotEmpty);
    await targetHub.waitForHellos(1);
    expect(io.text, contains('connected to ${targetHub.url}'));
  });

  test('text args keep the scriptable behavior (no menu)', () async {
    var menuOpened = false;
    final (slash, _, _) = registerHost(
      pickOption: (title, options, {initialKey}) async {
        menuOpened = true;
        return null;
      },
    );
    await slash(['127.0.0.1:9']);
    expect(menuOpened, isFalse);
  });
}
