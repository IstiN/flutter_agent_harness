/// herdr ↔ fa skill-install + session-resume contract (issue #818, ACH.2 /
/// ACH.3 / ACH.4).
///
/// herdr's `herdr integration` installs the herdr agent skill into fa's
/// USER-level skills root — `~/.fah/skills/herdr/` (never project scope;
/// the skill is machine-level tooling). The canonical skill content ships
/// in this repo at `docs/integrations/herdr/SKILL.md`; these tests install
/// exactly that content the way herdr's target would, and prove:
///
/// - ACH.2 — the installed skill is discovered (first-party `fah` source:
///   no third-party consent), `/skills`-visible, invocation renders, and
///   `HERDR_ENV=1` reaches the bash tool (the child environment merges
///   into `LocalShell` additively).
/// - ACH.3 — herdr's resume contract `fa --session <id|name>` re-attaches
///   a killed pane's session: run 2's provider request carries run 1's
///   transcript, by session NAME and by session ID (the resolution order
///   herdr's `agent_resume` plan relies on).
/// - ACH.4 — the same install on a machine WITHOUT herdr regresses
///   nothing: the skill loads but is inert outside `HERDR_ENV` (its own
///   guard), the turn completes, the bash tool sees no `HERDR_ENV`.
///
/// Runs against the mock LLM server — no herdr binary, no real provider.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/env/io_execution_env.dart';
import 'package:flutter_agent_harness/src/skills/skill_renderer.dart';
import 'package:test/test.dart';

import 'fa_cube_headless_helper.dart';

final _repoRoot = Directory.current.path;
final _canonicalSkill = '$_repoRoot/docs/integrations/herdr/SKILL.md';

// JSON-safe (no embedded double quotes): an unquoted var expands in the
// shell and stays empty when unset — the probe prints `HERDR_ENV=` then.
const _herdrEnvProbe = "printf 'HERDR_ENV=%s' \$HERDR_ENV";

Directory _tempDir(String prefix) =>
    Directory.systemTemp.createTempSync(prefix);

/// Installs the canonical skill into [home]/.fah/skills/herdr/ and writes
/// the mock-provider config — exactly the on-disk shape `herdr
/// integration` leaves behind (plus the test provider wiring).
void _installSkill(Directory home) {
  File('${home.path}/.fah/skills/herdr/SKILL.md')
    ..createSync(recursive: true)
    ..writeAsStringSync(File(_canonicalSkill).readAsStringSync());
}

Future<FaResult> runFa({
  required Directory home,
  required Directory workspace,
  required String prompt,
  required String baseUrl,
  Map<String, String> env = const {},
  List<String> args = const [],
}) {
  return spawnFa(
    fahArgs: [
      '--provider',
      'openai-completions',
      '--base-url',
      baseUrl,
      '--model',
      'mock-model',
      '--cwd',
      workspace.path,
      '--session-root',
      '${home.path}/.fah/sessions',
      ...args,
      '-p',
      prompt,
    ],
    // This lane itself runs under herdr (HERDR_ENV=1 ambient) — blank it
    // so only tests that inject the var see a herdr machine (the helper
    // convention: blank values read as unset at every consumer).
    env: {'HOME': home.path, 'HERDR_ENV': '', ...env},
  );
}

void main() {
  late Directory home;
  late Directory workspace;

  setUp(() {
    home = _tempDir('fa_herdr_home_');
    workspace = _tempDir('fa_herdr_ws_');
    _installSkill(home);
  });

  tearDown(() {
    home.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  test('ACH.2: installed skill is discovered from the user fah root', () async {
    final env = LocalExecutionEnv(cwd: workspace.path);
    final roots = defaultSkillRoots(cwd: workspace.path, homeDir: home.path);
    final skills = await discoverSkills(
      env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
    );
    final herdr = skills.where((s) => s.name == 'herdr').toList();
    expect(herdr, hasLength(1));
    expect(herdr.single.scope, SkillScope.user);
    expect(
      herdr.single.source,
      SkillSource.fah,
      reason: 'first-party root — loads with no third-party consent',
    );
    expect(herdr.single.filePath, '${home.path}/.fah/skills/herdr/SKILL.md');
    expect(
      herdr.single.manifest.notes,
      isEmpty,
      reason: 'frontmatter must use only known keys and plain tool grants',
    );
    expect(herdr.single.manifest.allowedTools, ['bash']);
  });

  test('ACH.2: skill invocation renders through the renderer', () async {
    final env = LocalExecutionEnv(cwd: workspace.path);
    final roots = defaultSkillRoots(cwd: workspace.path, homeDir: home.path);
    final skills = await discoverSkills(
      env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
    );
    final skill = skills.where((s) => s.name == 'herdr').single;
    final result = await renderSkillBody(env, skill, args: 'who is blocked');
    expect(result.body, contains('HERDR_ENV'));
    expect(result.body, contains('who is blocked'));
    expect(result.body, isNot(contains('---')), reason: 'frontmatter stripped');
  });

  test('ACH.2: HERDR_ENV=1 reaches the bash tool env', () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server.enqueueToolCall('bash', '{"command":"$_herdrEnvProbe"}');
    server.enqueueToolResultEcho();

    final result = await runFa(
      home: home,
      workspace: workspace,
      baseUrl: server.baseUrl,
      prompt: 'check whether we run inside herdr',
      env: {'HERDR_ENV': '1'},
    );

    expect(result.exitCode, 0, reason: result.output);
    expect(
      result.output,
      contains('HERDR_ENV=1'),
      reason: 'the inherited herdr env must reach LocalShell',
    );
  });

  test(
    'ACH.4: skill is inert without herdr — no HERDR_ENV, clean turn',
    () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      server.enqueueToolCall('bash', '{"command":"$_herdrEnvProbe"}');
      server.enqueueToolResultEcho();

      final result = await runFa(
        home: home,
        workspace: workspace,
        baseUrl: server.baseUrl,
        prompt: 'check whether we run inside herdr',
      );

      expect(result.exitCode, 0, reason: result.output);
      expect(
        result.output,
        contains('HERDR_ENV='),
        reason: 'the probe reply must carry an EMPTY value',
      );
      expect(result.output, isNot(contains('HERDR_ENV=1')));
    },
  );

  test(
    'ACH.3: fa --session <name> resumes the killed pane transcript',
    () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);

      server.enqueueText('BANANA noted');
      final first = await runFa(
        home: home,
        workspace: workspace,
        baseUrl: server.baseUrl,
        args: ['--session', 'herdr-resume'],
        prompt: 'remember the word BANANA',
        env: {'HERDR_ENV': '1'},
      );
      expect(first.exitCode, 0, reason: first.output);
      server.enqueueText('it was BANANA');
      final second = await runFa(
        home: home,
        workspace: workspace,
        baseUrl: server.baseUrl,
        args: ['--session', 'herdr-resume'],
        prompt: 'what word did I ask you to remember?',
        env: {'HERDR_ENV': '1'},
      );
      expect(second.exitCode, 0, reason: second.output);
      // The resumed request must carry the first run's transcript — that is
      // the whole resume contract herdr's `agent_resume` plan drives.
      expect(server.chatBodies, hasLength(2));
      expect(server.chatBodies.last, contains('BANANA'));
    },
  );

  test('ACH.3: fa --session <id> resumes too (herdr persists ids)', () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);

    server.enqueueText('MANGO noted');
    final first = await runFa(
      home: home,
      workspace: workspace,
      baseUrl: server.baseUrl,
      prompt: 'remember the word MANGO',
    );
    expect(first.exitCode, 0, reason: first.output);

    final sessionRoot = Directory('${home.path}/.fah/sessions');
    final sessionFiles = sessionRoot
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList();
    expect(sessionFiles, hasLength(1));
    // File layout: `<sessionsRoot>/<encoded-cwd>/<timestamp>_<id>.jsonl`
    // (session_repo.dart) — the id is the part after the last underscore.
    final sessionId = sessionFiles.single.uri.pathSegments.last
        .replaceAll('.jsonl', '')
        .split('_')
        .last;
    expect(sessionId, isNotEmpty);

    server.enqueueText('it was MANGO');
    final second = await runFa(
      home: home,
      workspace: workspace,
      baseUrl: server.baseUrl,
      args: ['--session', sessionId],
      prompt: 'what word?',
    );
    expect(second.exitCode, 0, reason: second.output);
    expect(server.chatBodies, hasLength(2));
    expect(server.chatBodies.last, contains('MANGO'));
  });
}
