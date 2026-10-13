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
      // Give the filesystem clock room to move: an actual rewrite must
      // bump the mtime past [before].
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await saveCliConfig(
        tmp.path,
        saved.withCustomProviders(saved.customProviders),
      );
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
    (AgentCli, FakeCliIO) bootCli({int? contextWindowCap}) {
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '${tmp.path}/sessions',
          homeDir: tmp.path,
          contextWindowCap: contextWindowCap,
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
      final edited = removeYamlPath((await env.readTextFile(path)).getOrThrow(), const [
        'auto_update',
      ]);
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

      // The next persist in the same session (/mode switch, approval
      // change, skill toggle…) saves from the BOOT snapshot.
      await persistShapedSave(bootSnapshot);

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

    test('the auto-update off→notify key drop is not resurrected',
        () async {
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

      await persistShapedSave(bootSnapshot);

      expect(
        loadCliConfig(tmp.path).autoUpdate,
        AutoUpdateMode.notify,
        reason: 'the drop must survive the next persist in the session',
      );
    });

    test('a global compaction pick is not overwritten by the boot value',
        () async {
      // The boot-loaded engine is non-default (classic); the settings-hub
      // pick is structured (global scope).
      configFile(tmp)
        ..createSync(recursive: true)
        ..writeAsStringSync('${ticketConfigYaml}compaction:\n'
            '  engine: classic\n');
      final bootSnapshot = loadCliConfig(tmp.path);
      expect(bootSnapshot.compactionEngine, CompactionEngine.classic);

      await globalCompactionPickWrite();
      expect(
        loadCliConfig(tmp.path).compactionEngine,
        CompactionEngine.structured,
        reason: 'the global pick must land on disk first',
      );

      await persistShapedSave(bootSnapshot);

      expect(
        loadCliConfig(tmp.path).compactionEngine,
        CompactionEngine.structured,
        reason: 'the pick must survive the next persist in the session',
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
  });
}
