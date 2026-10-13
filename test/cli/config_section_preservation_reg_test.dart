/// gh-1572: starting `fa` rewrites `~/.fah/config.yaml` from a freshly
/// built `CliConfig` and silently loses user sections (spills, subagents,
/// jobs, headless, agent, quota, tui, trajectory, waiting, power.hold).
///
/// The save path had three cooperating leaks:
/// 1. the boot's `persistConfig` (bin/fah_runapp.dart) built a NEW
///    `CliConfig` carrying only some fields — everything else reset to
///    constructor defaults in the object being saved;
/// 2. `CliConfig.withCustomProviders` — the copy helper
///    `saveCliConfig`'s merge-before-write step uses — drifted the same
///    way (also dropped spills/subagents/waiting/jobs/agentMode/
///    misuseBreaker/streamThinking);
/// 3. the `_diskPreservedSections` backstop did not list the dropped
///    keys, so they were not re-attached from disk either.
///
/// These tests pin: every parsed section survives a save round trip, the
/// `spills:` section renders in `toYaml`, the boot-shaped overlay save
/// keeps the provider triple AND every section, the disk backstop covers
/// every known section the emitter omits, and an unchanged save does not
/// rewrite the file.
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'agent_cli_test_support.dart';

File configFile(Directory tmp) => File('${tmp.path}/.fah/config.yaml');

/// The ticket's reproduction file: provider/model/baseUrl plus every
/// top-level section the boot rewrite dropped. Every value is
/// non-default so a round-trip assertion can never pass vacuously.
const ticketConfigYaml = '''
provider: openai-completions
model: openai/gpt-4o-mini
baseUrl: https://openrouter.ai/api/v1
spills:
  enabled: false
  threshold: 4096
  headChars: 3000
  tailChars: 2500
subagents:
  heartbeatMinutes: 5
  stallMinutes: 7
jobs:
  staleHours: 48
  logRetentionDays: 7
headless:
  shellJobDrainMs: 600
  shellJobQuietMs: 300
agent:
  mode: pi
  contextWindowCap: 256000
  misuseBreaker: false
quota:
  badge: true
  ttl_minutes: 30
tui:
  theme: ohmypi-dark
trajectory:
  wireDump: true
waiting:
  waitHeartbeatMinutes: 3
power:
  hold: session
''';

/// Asserts every section of the ticket's file loaded into [config].
void expectTicketSectionsLoaded(CliConfig config) {
  expect(config.spills?.enabled, false, reason: 'spills.enabled');
  expect(config.spills?.threshold, 4096, reason: 'spills.threshold');
  expect(config.spills?.headChars, 3000, reason: 'spills.headChars');
  expect(config.spills?.tailChars, 2500, reason: 'spills.tailChars');
  expect(config.subagents.heartbeatMinutes, 5, reason: 'subagents');
  expect(config.subagents.stallMinutes, 7, reason: 'subagents.stallMinutes');
  expect(config.jobs.staleHours, 48, reason: 'jobs.staleHours');
  expect(config.jobs.logRetentionDays, 7, reason: 'jobs.logRetentionDays');
  expect(
    config.headless.shellJobDrainMs,
    600,
    reason: 'headless.shellJobDrainMs',
  );
  expect(
    config.headless.shellJobQuietMs,
    300,
    reason: 'headless.shellJobQuietMs',
  );
  expect(config.agentLoadMode, 'pi', reason: 'agent.mode');
  expect(config.contextWindowCap, 256000, reason: 'agent.contextWindowCap');
  expect(config.misuseBreaker, false, reason: 'agent.misuseBreaker');
  expect(config.quota.badge, true, reason: 'quota.badge');
  expect(config.quota.ttlMinutes, 30, reason: 'quota.ttl_minutes');
  expect(config.tuiTheme, 'ohmypi-dark', reason: 'tui.theme');
  expect(config.wireDump, true, reason: 'trajectory.wireDump');
  expect(
    config.waiting.waitHeartbeatMinutes,
    3,
    reason: 'waiting.waitHeartbeatMinutes',
  );
  expect(config.powerHold?.value, 'session', reason: 'power.hold');
}

void main() {
  group('config save never drops sections (gh-1572)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-gh1572-config-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('saveCliConfig round trip: every section survives '
        'loadCliConfig → save-shaped CliConfig → saveCliConfig', () async {
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(ticketConfigYaml);
      final saved = loadCliConfig(tmp.path);
      expectTicketSectionsLoaded(saved);

      // The shape saveCliConfig itself produces via its
      // merge-before-write step (withCustomProviders identity).
      await saveCliConfig(
        tmp.path,
        saved.withCustomProviders(saved.customProviders),
      );

      expectTicketSectionsLoaded(loadCliConfig(tmp.path));
    });

    test('the boot-shaped persistConfig save keeps the provider triple '
        'and every section', () async {
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(ticketConfigYaml);
      final saved = loadCliConfig(tmp.path);

      // Mirrors bin/fah_runapp.dart persistConfig: the saved config as
      // the base, only the session-live overlays on top. Explicit
      // --provider/--base-url/--model flags never touch the saved
      // defaults (the provider/model triple is per-folder state).
      final persistShaped = saved.copyWith(
        mode: 'code',
        approvalMode: 'yolo',
        allowedTools: const [],
        modelRoles: saved.modelRoles,
        customProviders: saved.customProviders,
        models: saved.models,
        mcp: saved.mcp,
        skillsAccess: saved.skillsAccess,
        skillToggles: saved.skillToggles,
        cube: saved.cube,
        tools: saved.tools,
      );
      expect(persistShaped.providerKind, saved.providerKind);
      expect(persistShaped.modelId, saved.modelId);
      expect(persistShaped.baseUrl, saved.baseUrl);

      await saveCliConfig(tmp.path, persistShaped);
      final reloaded = loadCliConfig(tmp.path);
      expect(reloaded.providerKind, 'openai-completions');
      expect(reloaded.modelId, 'openai/gpt-4o-mini');
      expect(reloaded.baseUrl, 'https://openrouter.ai/api/v1');
      expectTicketSectionsLoaded(reloaded);
    });

    test('toYaml renders the spills section when set', () {
      final config = CliConfig(
        spills: SpillsConfig(
          enabled: false,
          threshold: 4096,
          headChars: 3000,
          tailChars: 2500,
        ),
      );
      final yaml = config.toYaml();
      expect(
        yaml,
        contains(
          'spills:\n'
          '  enabled: false\n'
          '  threshold: 4096\n'
          '  headChars: 3000\n'
          '  tailChars: 2500\n',
        ),
      );
      // The reloaded config parses it back (the render is valid yaml).
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(yaml);
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.spills?.threshold, 4096);
    });

    test('toYaml omits the spills section at defaults', () {
      expect(CliConfig().toYaml(), isNot(contains('spills:')));
    });

    test('the disk backstop re-attaches every known section block the '
        'emitter omitted', () async {
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(ticketConfigYaml);
      // A config that renders none of the sections above (all
      // defaults): the raw on-disk blocks must survive the save.
      await saveCliConfig(tmp.path, CliConfig(mode: 'code'));
      expectTicketSectionsLoaded(loadCliConfig(tmp.path));
    });

    test('an unchanged save does not rewrite the file', () async {
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(ticketConfigYaml);
      final saved = loadCliConfig(tmp.path);
      await saveCliConfig(
        tmp.path,
        saved.withCustomProviders(saved.customProviders),
      );
      final path = configFile(tmp).path;
      final before = File(path).lastModifiedSync();
      final textBefore = File(path).readAsStringSync();

      // Clock-independent short-circuit proof: a real write goes through
      // a unique `config.yaml.tmp.<pid>.<n>` file (create + rename), a
      // short-circuit creates nothing. The directory watch reports the
      // file-system EVENTS, not mtimes, so the assertion cannot pass
      // vacuously on coarse-clock filesystems (gh-1572 rework). An
      // unsupported watch platform degrades to the mtime pin below.
      final events = <FileSystemEvent>[];
      final watch = Directory('${tmp.path}/.fah').watch();
      final subscription = watch.listen(
        events.add,
        onError: (Object _) {
          // Unsupported platform/filesystem: the mtime pin still holds.
        },
        cancelOnError: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await saveCliConfig(
        tmp.path,
        saved.withCustomProviders(saved.customProviders),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await subscription.cancel();

      expect(
        events.where((event) => event.path.contains('.tmp.')),
        isEmpty,
        reason: 'an unchanged save must not even create the temp file',
      );
      // The watch settle (100 ms) already gave the filesystem clock room
      // to move: an actual rewrite must bump the mtime past [before].
      expect(File(path).lastModifiedSync(), before);
      expect(File(path).readAsStringSync(), textBefore);
    });
  });

  group('a sanctioned mid-session write survives the next persist '
      '(gh-1572 rework)', () {
    late Directory tmp;
    late LocalExecutionEnv env;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-gh1572-persist-');
      env = LocalExecutionEnv(cwd: tmp.path);
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    /// Boots the settings-flow cli over the seeded user config. The
    /// flow's own writes go through [env] (the seam the flows use); the
    /// boot snapshot and every save go through the real file
    /// (`loadCliConfig`/`saveCliConfig`), exactly the two views
    /// bin/fah_runapp.dart holds.
    (AgentCli, FakeCliIO) bootCli({
      int? contextWindowCap,
      Future<void> Function()? onUserConfigFileChanged,
    }) {
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '${tmp.path}/sessions',
          homeDir: tmp.path,
          contextWindowCap: contextWindowCap,
          onUserConfigFileChanged: onUserConfigFileChanged,
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      return (cli, io);
    }

    /// The boot-shaped persistConfig save (bin/fah_runapp.dart): the
    /// snapshot as the copyWith base, only the session-live overlays on
    /// top.
    Future<void> persistShapedSave(CliConfig snapshot) => saveCliConfig(
      tmp.path,
      snapshot.copyWith(
        mode: 'code',
        approvalMode: 'yolo',
        allowedTools: const [],
      ),
    );

    /// Applies the settings-hub clear-cap write to the user config the
    /// way `_clearContextCap` lands it: a surgical `removeYamlPath` of
    /// the cap key (the whole block when it empties), then a direct file
    /// write — no `saveCliConfig` involved.
    Future<void> clearCapWrite() async {
      final path = configFile(tmp).path;
      final edited = removeYamlPath(
        (await env.readTextFile(path)).getOrThrow(),
        const ['agent', 'contextWindowCap'],
      );
      loadYaml(edited); // the flows validate before writing
      await env.writeFile(path, edited);
    }

    /// Applies the auto-update off→notify write the way
    /// `_dropAutoUpdateKey` lands it: the key line removed, everything
    /// else byte-for-byte.
    Future<void> dropAutoUpdateKeyWrite() async {
      final path = configFile(tmp).path;
      final edited = removeYamlPath(
        (await env.readTextFile(path)).getOrThrow(),
        const ['auto_update'],
      );
      loadYaml(edited);
      await env.writeFile(path, edited);
    }

    /// Applies the Compaction flow's global-scope pick the way
    /// `_writeCompactionEngineYaml` lands it: the validated
    /// `compaction.engine` upsert.
    Future<void> globalCompactionPickWrite() async {
      final path = configFile(tmp).path;
      final edited = upsertYamlPath(
        (await env.readTextFile(path)).getOrThrow(),
        const ['compaction', 'engine'],
        configLeafLines(CompactionEngine.structured.value, depth: 1),
      );
      loadYaml(edited);
      await env.writeFile(path, edited);
    }

    test('the settings clear-cap removal is not resurrected', () async {
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(ticketConfigYaml);
      // Boot: the snapshot persistConfig copies from (a late final,
      // loaded once at boot — it knows nothing about the flow's write).
      final bootSnapshot = loadCliConfig(tmp.path);
      expect(bootSnapshot.contextWindowCap, 256000);

      await clearCapWrite();
      expect(
        loadCliConfig(tmp.path).contextWindowCap,
        isNull,
        reason: 'the clear-cap write must land on disk first',
      );

      // The rework wiring (bin/fah_runapp.dart): every sanctioned direct
      // write re-syncs the snapshot via onUserConfigFileChanged (its
      // firing from the real flow is pinned by the auto-update drop
      // tests), so the next persist renders the freshest on-disk truth.
      final snapshot = loadCliConfig(tmp.path);

      // Any later persist trigger in the same session (/mode switch,
      // approval change, skill toggle…).
      await persistShapedSave(snapshot);

      final reloaded = loadCliConfig(tmp.path);
      expect(
        reloaded.contextWindowCap,
        isNull,
        reason: 'the removal must survive the next persist in the session',
      );
      // The sibling keys the clear never touched survive verbatim.
      expect(reloaded.agentLoadMode, 'pi');
      expect(reloaded.misuseBreaker, isFalse);
    });

    test('the auto-update off→notify key drop is not resurrected', () async {
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync('${ticketConfigYaml}auto_update: false\n');
      final bootSnapshot = loadCliConfig(tmp.path);
      expect(bootSnapshot.autoUpdate, AutoUpdateMode.off);

      await dropAutoUpdateKeyWrite();
      expect(
        loadCliConfig(tmp.path).autoUpdate,
        AutoUpdateMode.notify,
        reason: 'the key drop must land on disk first',
      );

      final snapshot = loadCliConfig(tmp.path);
      await persistShapedSave(snapshot);

      expect(
        loadCliConfig(tmp.path).autoUpdate,
        AutoUpdateMode.notify,
        reason: 'the drop must survive the next persist in the session',
      );
    });

    test(
      'a global compaction pick is not overwritten by the boot value',
      () async {
        // The boot-loaded engine is non-default (classic); the settings-hub
        // pick is structured (global scope).
        configFile(tmp)
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${ticketConfigYaml}compaction:\n'
            '  engine: classic\n',
          );
        final bootSnapshot = loadCliConfig(tmp.path);
        expect(bootSnapshot.compactionEngine, CompactionEngine.classic);

        await globalCompactionPickWrite();
        expect(
          loadCliConfig(tmp.path).compactionEngine,
          CompactionEngine.structured,
          reason: 'the global pick must land on disk first',
        );

        final snapshot = loadCliConfig(tmp.path);
        await persistShapedSave(snapshot);

        expect(
          loadCliConfig(tmp.path).compactionEngine,
          CompactionEngine.structured,
          reason: 'the pick must survive the next persist in the session',
        );
      },
    );

    test('the real auto-update flow fires the re-sync hook', () async {
      // Input-free flow, both write branches: off → notify lands the
      // DROP branch, notify → on lands the shared surgical-upsert path
      // (`_upsertConfigYaml`). Every sanctioned user-file write must
      // fire the hook exactly once.
      var resyncs = 0;
      final (cli, _) = bootCli(onUserConfigFileChanged: () async => resyncs++);
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync('${ticketConfigYaml}auto_update: false\n');

      cli.config.autoUpdate = AutoUpdateMode.off;
      await cli.startAutoUpdateFlow();
      expect(resyncs, 1, reason: 'the drop branch fires the hook');
      expect(loadCliConfig(tmp.path).autoUpdate, AutoUpdateMode.notify);

      cli.config.autoUpdate = AutoUpdateMode.notify;
      await cli.startAutoUpdateFlow();
      expect(resyncs, 2, reason: 'the upsert branch fires the hook');
      expect(loadCliConfig(tmp.path).autoUpdate, AutoUpdateMode.on);
    });

    test('the flow re-sync keeps a sanctioned drop alive across a real '
        'persist', () async {
      // End to end: the boot snapshot, the real flow's drop, the hook
      // re-sync (wired exactly like bin/fah_runapp.dart), then the
      // boot-shaped persist.
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync('${ticketConfigYaml}auto_update: false\n');
      var snapshot = loadCliConfig(tmp.path);
      expect(snapshot.autoUpdate, AutoUpdateMode.off);

      final (cli, _) = bootCli(
        onUserConfigFileChanged: () async {
          snapshot = loadCliConfig(tmp.path);
        },
      );
      cli.config.autoUpdate = AutoUpdateMode.off;
      await cli.startAutoUpdateFlow();

      await persistShapedSave(snapshot);

      expect(
        loadCliConfig(tmp.path).autoUpdate,
        AutoUpdateMode.notify,
        reason:
            'the drop survives the persist because the flow re-synced '
            'the snapshot through the hook',
      );
    });

    test('a providersQueue block survives a save the emitter cannot '
        'render', () async {
      // The queue section (issue #418) has no typed renderer at all —
      // like `waiting:`, its raw on-disk block is the only faithful form,
      // so the backstop must carry it.
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'providersQueue:\n'
          '  - name: kimi_me\n'
          '    provider: kimi\n',
        );
      await saveCliConfig(tmp.path, CliConfig(mode: 'code'));
      final text = File(configFile(tmp).path).readAsStringSync();
      expect(
        text,
        contains('providersQueue:\n  - name: kimi_me\n    provider: kimi\n'),
        reason: 'the raw queue block must survive a whole-file save',
      );
    });

    /// Waits until [predicate] holds against the accumulated flow output.
    /// The flows loop on their menus, so steps are sequenced by picker
    /// renders (`type a number:` prints once per render), never by
    /// re-matching earlier text (the settings_flow_test pattern).
    Future<void> waitForIo(
      FakeCliIO io,
      bool Function() predicate, {
      Duration timeout = const Duration(seconds: 10),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!predicate()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('timed out waiting for flow output; got:\n${io.out}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<void> waitRenders(FakeCliIO io, int n) => waitForIo(
      io,
      () => 'type a number:'.allMatches(io.out.toString()).length >= n,
    );

    test('the real ttsr toggle flow fires the re-sync hook', () async {
      // _writeTtsrSection is a direct USER-config writer, exactly like
      // _clearContextCap/_dropAutoUpdateKey — it must fire the hook or
      // the next persist re-renders the boot block over the edit.
      var resyncs = 0;
      final (cli, io) = bootCli(
        onUserConfigFileChanged: () async {
          resyncs++;
        },
      );
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'model: test-model\n'
          'ttsr:\n'
          '  rules:\n'
          '    - name: no-secrets\n'
          "      pattern: 'sk-[a-zA-Z0-9]{8}'\n"
          '      body: Never echo secrets.\n'
          '      enabled: false\n',
        );

      final run = cli.run();
      final flow = cli.startTtsrRulesFlow();
      await waitRenders(io, 1); // main menu (rule/add/done)
      io.sendLine('1'); // the no-secrets rule → its submenu
      await waitRenders(io, 2); // rule submenu (toggle/delete/back)
      io.sendLine('1'); // toggle → enable
      await waitForIo(io, () => io.out.toString().contains('ttsr saved →'));
      await waitRenders(io, 3); // the main menu re-rendered
      io.sendLine('3'); // done (1=rule, 2=add, 3=done)
      await flow;
      io.sendLine('/exit');
      await run;

      expect(resyncs, 1, reason: 'the ttsr write must fire the hook');
      expect(
        loadCliConfig(tmp.path).ttsr?.rules.single.enabled,
        isTrue,
        reason: 'the toggle must land on disk',
      );
    });

    test('the real mcp edit flow fires the re-sync hook', () async {
      // _writeMcpSection is the last remaining direct USER-config writer
      // without the hook — same data-loss class as the ttsr flow.
      var resyncs = 0;
      final (cli, io) = bootCli(
        onUserConfigFileChanged: () async {
          resyncs++;
        },
      );
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'model: test-model\n'
          'mcp:\n'
          '  servers:\n'
          '    fs:\n'
          '      command: npx\n'
          "      args: ['-y', '@modelcontextprotocol/server-fs', '/tmp']\n",
        );

      final run = cli.run();
      final flow = cli.startMcpServersFlow();
      await waitRenders(io, 1); // main menu (fs/add/done)
      io.sendLine('1'); // the fs server → its submenu
      await waitRenders(io, 2); // server submenu (edit/delete/back)
      io.sendLine('1'); // edit
      await waitForIo(io, () => io.out.toString().contains('command ('));
      io.sendLine('node2'); // command
      io.sendLine('srv.js, --port, 9'); // args
      io.sendLine('BAZ=qux'); // env
      await waitForIo(io, () => io.out.toString().contains('mcp saved →'));
      await waitRenders(io, 3); // the main menu re-rendered
      io.sendLine('3'); // done (1=fs, 2=add, 3=done)
      await flow;
      io.sendLine('/exit');
      await run;

      expect(resyncs, 1, reason: 'the mcp write must fire the hook');
      final server =
          loadCliConfig(tmp.path).mcp?.servers['fs'] as McpStdioServerConfig?;
      expect(server?.command, 'node2', reason: 'the edit must land on disk');
    });

    test('the ttsr toggle survives the next persist (flow re-sync)', () async {
      // End to end: boot snapshot → the real flow's write → the hook
      // re-sync (wired exactly like bin/fah_runapp.dart) → the
      // boot-shaped persist. Without the hook the save re-renders the
      // stale boot block (enabled: false) over the toggle.
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'model: test-model\n'
          'ttsr:\n'
          '  rules:\n'
          '    - name: no-secrets\n'
          "      pattern: 'sk-[a-zA-Z0-9]{8}'\n"
          '      body: Never echo secrets.\n'
          '      enabled: false\n',
        );
      var snapshot = loadCliConfig(tmp.path);
      expect(snapshot.ttsr?.rules.single.enabled, isFalse);

      final (cli, io) = bootCli(
        onUserConfigFileChanged: () async {
          snapshot = loadCliConfig(tmp.path);
        },
      );
      final run = cli.run();
      final flow = cli.startTtsrRulesFlow();
      await waitRenders(io, 1);
      io.sendLine('1');
      await waitRenders(io, 2);
      io.sendLine('1');
      await waitForIo(io, () => io.out.toString().contains('ttsr saved →'));
      await waitRenders(io, 3);
      io.sendLine('3');
      await flow;
      io.sendLine('/exit');
      await run;

      await persistShapedSave(snapshot);

      expect(
        loadCliConfig(tmp.path).ttsr?.rules.single.enabled,
        isTrue,
        reason:
            'the toggle survives the persist because the flow re-synced '
            'the snapshot through the hook',
      );
    });

    test('the mcp edit survives the next persist (flow re-sync)', () async {
      // Same end-to-end shape for the mcp writer: without the hook the
      // persist overlay (`cli.config.mcpConfig?.config ?? saved.mcp` —
      // the CLI host never assigns mcpConfig) re-rendered the boot
      // snapshot's section over the edit.
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'model: test-model\n'
          'mcp:\n'
          '  servers:\n'
          '    fs:\n'
          '      command: npx\n'
          "      args: ['-y', '@modelcontextprotocol/server-fs', '/tmp']\n",
        );
      var snapshot = loadCliConfig(tmp.path);
      final bootCommand =
          (snapshot.mcp?.servers['fs'] as McpStdioServerConfig?)?.command;
      expect(bootCommand, 'npx');

      final (cli, io) = bootCli(
        onUserConfigFileChanged: () async {
          snapshot = loadCliConfig(tmp.path);
        },
      );
      final run = cli.run();
      final flow = cli.startMcpServersFlow();
      await waitRenders(io, 1);
      io.sendLine('1');
      await waitRenders(io, 2);
      io.sendLine('1');
      await waitForIo(io, () => io.out.toString().contains('command ('));
      io.sendLine('node2');
      io.sendLine('srv.js, --port, 9');
      io.sendLine('BAZ=qux');
      await waitForIo(io, () => io.out.toString().contains('mcp saved →'));
      await waitRenders(io, 3);
      io.sendLine('3');
      await flow;
      io.sendLine('/exit');
      await run;

      await persistShapedSave(snapshot);

      final server =
          loadCliConfig(tmp.path).mcp?.servers['fs'] as McpStdioServerConfig?;
      expect(
        server?.command,
        'node2',
        reason:
            'the edit survives the persist because the flow re-synced '
            'the snapshot through the hook',
      );
    });
  });
}
