/// Issue #927 — the third-party skills consent cluster, the lib/src/cli
/// surface #914's harness-CWD move dropped from the PTY suites.
///
/// Booting `fa` in a project that carries Claude/Copilot/Codex skill roots
/// (`.claude/skills` …) must ask the user ONCE — on the REAL first frame,
/// through the shared wizard picker — whether those directories may be read:
/// - "Not now" (Esc) keeps them disabled and asks again on the next launch;
/// - "Allow" lists them in `/skills` and is REMEMBERED across launches;
/// - "Never" hides them and is remembered the same way;
/// - a project with no third-party roots never asks.
///
/// Every assertion is anchored on real rendered frames (`waitForScreen`) or
/// the settled raw stream with a scripted MockLlmServer — no network, no
/// synthetic coverage. Pickers are driven by type-to-filter + Enter, the
/// same mechanism the #595 suite pins.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

/// The wizard-picker title of the one-time consent dialog. Short enough to
/// stay on one 80-col row, so `contains` cannot straddle a wrap.
const _dialogTitle = 'Found Claude/Copilot/Codex skills or agents';

/// Skills seeded into every consent workspace: `greet` is OWN (`.fah`,
/// always readable), `deploy` is CLAUDE (`.claude`, consent-gated). Names
/// sit in the first columns of their `/skills` rows, so the assertions stay
/// wrap-safe at 80 columns.
const _ownSkill = 'greet';
const _thirdPartySkill = 'deploy';

/// Seeds a temp HOME (mock-provider config, no skills decision yet) and a
/// temp project with the own skill and — when [withClaudeSkill] — the
/// third-party `.claude/skills` root that arms the consent dialog.
({Directory home, Directory workspace}) _seedProject({
  required MockLlmServer server,
  bool withClaudeSkill = true,
}) {
  final home = Directory.systemTemp.createTempSync('fa927_home_');
  File('${home.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
allowedTools: []
# The consent suite tests the ASK flow: granted is the config default
# (cli_config.dart), so the ask decision must be pinned explicitly or the
# startup dialog never fires.
skills:
  access: ask
''');
  final workspace = Directory.systemTemp.createTempSync('fa927_ws_');
  File(
    '${workspace.path}/.fah/skills/$_ownSkill/SKILL.md',
  ).createSync(recursive: true);
  File('${workspace.path}/.fah/skills/$_ownSkill/SKILL.md').writeAsStringSync(
    '---\nname: $_ownSkill\ndescription: say hi\n---\nWave at the user.\n',
  );
  if (withClaudeSkill) {
    final claudeSkill = File(
      '${workspace.path}/.claude/skills/$_thirdPartySkill/SKILL.md',
    )..createSync(recursive: true);
    claudeSkill.writeAsStringSync(
      '---\nname: $_thirdPartySkill\ndescription: ship it\n---\n'
      'Deploy the app.\n',
    );
  }
  return (home: home, workspace: workspace);
}

Future<FaCliHarness> _spawn(Directory home, Directory workspace) async {
  final harness = await FaCliHarness.spawn(
    workingDirectory: workspace.path,
    extraEnv: {'HOME': home.path},
  );
  return harness;
}

void main() {
  late MockLlmServer server;
  setUpAll(() async {
    server = await MockLlmServer.start();
  });
  tearDownAll(() async {
    await server.stop();
  });

  test('boot asks consent for third-party skills; Not now keeps them disabled '
      'and asks again next launch', () async {
    final (:home, :workspace) = _seedProject(server: server);
    addTearDown(() => workspace.deleteSync(recursive: true));
    addTearDown(() => home.deleteSync(recursive: true));

    final harness = await _spawn(home, workspace);
    addTearDown(harness.close);
    await harness.waitForBoot();

    // The dialog is on the first frame with all three options painted.
    final dialog = await harness.waitForScreen(
      _dialogTitle,
      timeout: const Duration(seconds: 20),
    );
    expect(dialog, contains('Allow'));
    expect(dialog, contains('Not now'));
    expect(dialog, contains('Never'));

    // Esc = "Not now": third-party skills stay off, with the way out.
    harness.sendEscape();
    await harness.waitForScreen(
      'third-party skills stay disabled',
      timeout: const Duration(seconds: 10),
    );

    // /skills lists the own skill but NOT the claude one, plus the
    // disabled hint naming the escape hatch.
    await harness.runSlashCommand('/skills');
    final listed = await harness.waitForScreen(
      'Claude/Copilot/Codex skills are disabled',
      timeout: const Duration(seconds: 10),
    );
    expect(listed, contains('$_ownSkill — say hi'));
    expect(listed, isNot(contains(_thirdPartySkill)));
    await harness.close();

    // "Not now" is deliberately not remembered: the next launch asks.
    final harness2 = await _spawn(home, workspace);
    addTearDown(harness2.close);
    await harness2.waitForBoot();
    await harness2.waitForScreen(
      _dialogTitle,
      timeout: const Duration(seconds: 20),
    );
  });

  test('Allow lists third-party skills in /skills and is remembered across '
      'launches', () async {
    final (:home, :workspace) = _seedProject(server: server);
    addTearDown(() => workspace.deleteSync(recursive: true));
    addTearDown(() => home.deleteSync(recursive: true));

    final harness = await _spawn(home, workspace);
    addTearDown(harness.close);
    await harness.waitForBoot();
    await harness.waitForScreen(
      _dialogTitle,
      timeout: const Duration(seconds: 20),
    );

    // Type-to-filter down to the Allow row and take it.
    harness.sendText('allow');
    harness.sendEnter();
    await harness.waitForText(
      'skills access: granted',
      timeout: const Duration(seconds: 10),
    );

    // The claude skill is now listed next to the own one.
    await harness.runSlashCommand('/skills');
    final listed = await harness.waitForScreen(
      '$_thirdPartySkill — ship it',
      timeout: const Duration(seconds: 10),
    );
    expect(listed, contains('$_ownSkill — say hi'));
    expect(listed, isNot(contains('are disabled')));
    await harness.close();

    // The decision persists: the next launch does NOT ask again and the
    // third-party skill stays visible.
    final harness2 = await _spawn(home, workspace);
    addTearDown(harness2.close);
    await harness2.waitForBoot();
    await harness2.waitForOutput(
      settleMs: 400,
      timeout: const Duration(seconds: 5),
    );
    expect(harness2.screenText, isNot(contains(_dialogTitle)));
    await harness2.runSlashCommand('/skills');
    await harness2.waitForScreen(
      '$_thirdPartySkill — ship it',
      timeout: const Duration(seconds: 10),
    );
  });

  test(
    'Never hides third-party skills and is remembered across launches',
    () async {
      final (:home, :workspace) = _seedProject(server: server);
      addTearDown(() => workspace.deleteSync(recursive: true));
      addTearDown(() => home.deleteSync(recursive: true));

      final harness = await _spawn(home, workspace);
      addTearDown(harness.close);
      await harness.waitForBoot();
      await harness.waitForScreen(
        _dialogTitle,
        timeout: const Duration(seconds: 20),
      );

      harness.sendText('never');
      harness.sendEnter();
      await harness.waitForText(
        'skills access: denied',
        timeout: const Duration(seconds: 10),
      );

      await harness.runSlashCommand('/skills');
      final listed = await harness.waitForScreen(
        'Claude/Copilot/Codex skills are disabled',
        timeout: const Duration(seconds: 10),
      );
      expect(listed, contains('$_ownSkill — say hi'));
      expect(listed, isNot(contains(_thirdPartySkill)));
      await harness.close();

      // "Never" IS remembered: the next launch skips the dialog.
      final harness2 = await _spawn(home, workspace);
      addTearDown(harness2.close);
      await harness2.waitForBoot();
      await harness2.waitForOutput(
        settleMs: 400,
        timeout: const Duration(seconds: 5),
      );
      expect(harness2.screenText, isNot(contains(_dialogTitle)));
    },
  );

  test('no third-party roots, no consent ask', () async {
    final (:home, :workspace) = _seedProject(
      server: server,
      withClaudeSkill: false,
    );
    addTearDown(() => workspace.deleteSync(recursive: true));
    addTearDown(() => home.deleteSync(recursive: true));

    final harness = await _spawn(home, workspace);
    addTearDown(harness.close);
    await harness.waitForBoot();
    await harness.waitForOutput(
      settleMs: 400,
      timeout: const Duration(seconds: 5),
    );
    expect(harness.screenText, isNot(contains(_dialogTitle)));

    // /skills still works and never claims third-party skills are gated.
    await harness.runSlashCommand('/skills');
    final listed = await harness.waitForScreen(
      '$_ownSkill — say hi',
      timeout: const Duration(seconds: 10),
    );
    expect(listed, isNot(contains('are disabled')));
  });
}
