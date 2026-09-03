/// Headless `--tools` flag proof (issue #19 AC16):
///
/// Boots the real CLI as a subprocess against the mock LLM and asserts on
/// the recorded `/chat/completions` request body:
///
/// - `--tools web_search=off,dap=off` keeps the disabled tools off the wire
///   `tools` array (no `web_search`/`web_fetch`/`dap_*`) while the rest of
///   the surface (`read`, `bash`) stays.
/// - Without the flag the default wiring exposes `web_search` — proving the
///   flag, not a boot-wide absence, removed it.
/// - A malformed value (`bogus=maybe`) fails as a usage error.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'mock_llm_server.dart';

void main() {
  late Directory tempHome;
  late Directory workspace;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('headless_tools_home_');
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('approvalMode: yolo\n');
    workspace = Directory.systemTemp.createTempSync('headless_tools_ws_');
  });

  tearDown(() {
    tempHome.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  /// Spawns one headless `fah` prompt (temp HOME, `--cwd <workspace>`),
  /// same convention as `fa_cube_headless_helper.dart`, with [extraArgs]
  /// appended before the prompt.
  Future<ProcessResult> runHeadless(
    MockLlmServer server,
    List<String> extraArgs,
  ) {
    return Process.run(
      'dart',
      [
        'run',
        'bin/fah.dart',
        '--provider',
        'openai-completions',
        '--base-url',
        server.baseUrl,
        '--model',
        'mock-model',
        '--cwd',
        workspace.path,
        ...extraArgs,
        '-p',
        'hi',
      ],
      workingDirectory: Directory.current.path,
      environment: {'OPENAI_API_KEY': 'mock', 'HOME': tempHome.path},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(minutes: 4));
  }

  /// The `tools[i].function.name` list of the single recorded
  /// `/chat/completions` request.
  List<String> wireToolNames(MockLlmServer server) {
    final body = jsonDecode(server.chatBodies.single) as Map<String, dynamic>;
    final tools = body['tools']! as List<Object?>;
    return [
      for (final tool in tools)
        ((tool! as Map<String, dynamic>)['function']
                as Map<String, dynamic>)['name']!
            as String,
    ];
  }

  test(
    '--tools web_search=off,dap=off keeps disabled tools off the wire',
    () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      server.enqueueText('done');

      final result = await runHeadless(server, [
        '--tools',
        'web_search=off,dap=off',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final names = wireToolNames(server);
      expect(
        names
            .where(
              (name) =>
                  name == 'web_search' ||
                  name == 'web_fetch' ||
                  name.startsWith('dap_'),
            )
            .toList(),
        isEmpty,
        reason: 'disabled tools must not reach the model, got: $names',
      );
      expect(names, containsAll(['read', 'bash']));
    },
  );

  test('without --tools the default wiring exposes web_search', () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server.enqueueText('done');

    final result = await runHeadless(server, const []);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(wireToolNames(server), contains('web_search'));
  });

  test('--tools bogus=maybe fails as a usage error', () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);

    final result = await runHeadless(server, ['--tools', 'bogus=maybe']);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('invalid --tools spec'));
    expect(result.stderr, contains('bogus=maybe'));
  });
}
