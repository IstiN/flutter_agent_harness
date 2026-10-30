import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart'
    show readSqliteSectionPrompt;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:image/image.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// gh-1984 media-slot CLI wiring (split out of agent_cli_test.dart —
/// the whole-tree 2800-line loc ceiling, review rework): the plain
/// CLI's `inspect_image`/`transcribe_audio` registration, the `/tools`
/// capabilities, and the read auto-route's /cost sink follow the LIVE
/// slot state (the host resolver / the persisted `models:` slots), not
/// a boot snapshot.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  /// The plain CLI boot used by the capability tests (the `cliFor` shape
  /// of agent_cli_test.dart, narrowed to the arguments these tests pass).
  AgentCli cliFor(StreamFunction streamFunction) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive-Value]',
      env: env,
      sessionRoot: '/sessions',
    ),
    io: io,
    streamFunction: streamFunction,
  );

  test(
    'gh-1984 AC1: /tools shows inspect_image off with the configure hint',
    () async {
      final fake = FakeStreamFunction([]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(() => cli.agent.state.tools.isNotEmpty);
      io.sendLine('/tools');
      await waitForIt(() => io.out.toString().contains('inspect_image'));
      io.sendLine('/exit');
      await run;
      final line = io.out
          .toString()
          .split('\n')
          .firstWhere((l) => l.startsWith('inspect_image'.padRight(16)));
      expect(line, contains(' off '));
      expect(line, contains('models.slots.vision'));
      expect(line, contains('--vision-model'));
    },
  );

  test(
    'gh-1984 AC1: /tools shows inspect_image on when the slot serves',
    () async {
      final fake = FakeStreamFunction([]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          visionConfig: InspectImageConfig(
            modelId: 'glm-5.3-flash',
            apiKey: '[REDACTED:Sensitive-Value]',
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();
      await waitForIt(() => cli.agent.state.tools.isNotEmpty);
      io.sendLine('/tools');
      await waitForIt(() => io.out.toString().contains('inspect_image'));
      io.sendLine('/exit');
      await run;
      final line = io.out
          .toString()
          .split('\n')
          .firstWhere((l) => l.startsWith('inspect_image'.padRight(16)));
      expect(line, contains(' on '));
    },
  );

  test(
    'gh-1984 AC9: /tools shows transcribe_audio off naming the slot',
    () async {
      final fake = FakeStreamFunction([]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(() => cli.agent.state.tools.isNotEmpty);
      io.sendLine('/tools');
      await waitForIt(() => io.out.toString().contains('transcribe_audio'));
      io.sendLine('/exit');
      await run;
      final line = io.out
          .toString()
          .split('\n')
          .firstWhere((l) => l.startsWith('transcribe_audio'.padRight(16)));
      expect(line, contains(' off '));
      expect(line, contains('models.slots.transcription'));
      expect(line, contains('--transcribe-model'));
    },
  );

  test(
    'gh-1984 AC10: the CLI read tool carries the audio note opt-in',
    () async {
      // The threading proof: mediaFileReadNotes rides AgentCliConfig →
      // wireAgentCore → the registered read tool (not just readFileTool
      // directly).
      await env.writeBinaryFile('/work/note.mp3', Uint8List.fromList([1, 2]));
      final fake = FakeStreamFunction([]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          mediaFileReadNotes: true,
          transcribeAvailable: () => true,
        ),
        io: io,
        streamFunction: fake.call,
      );
      final read = cli.agent.state.tools.whereType<AgentTool>().firstWhere(
        (t) => t.name == 'read',
      );
      final result = await read.execute({'path': '/work/note.mp3'}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, contains('[Audio file: /work/note.mp3'));
      expect(text, contains('transcribe_audio'));
    },
  );

  test(
    'gh-1984: the sqlite read swap keeps the auto-route /cost sink',
    () async {
      // The sqlite variant swap REBUILDS the read tool; the rebuilt variant
      // must ride the SAME default /cost sink as the boot one (AC2): the
      // auto-route's vision side-call lands in /stats even when the swap
      // fired mid-session.
      final img = Image(width: 2, height: 2)..getPixel(0, 0).r = 255;
      await env.writeBinaryFile(
        '/work/shot.png',
        Uint8List.fromList(encodePng(img)),
      );
      var calls = 0;
      final client = http_testing.MockClient.streaming((request, body) async {
        calls++;
        final payload = jsonEncode({
          'id': 'chatcmpl-test',
          'object': 'chat.completion.chunk',
          'created': 1234567890,
          'model': 'glm-5.3-flash',
          'choices': [
            {
              'index': 0,
              'delta': {'role': 'assistant', 'content': 'A tiny red pixel.'},
              'finish_reason': null,
            },
          ],
        });
        final done = jsonEncode({
          'id': 'chatcmpl-test',
          'object': 'chat.completion.chunk',
          'created': 1234567890,
          'model': 'glm-5.3-flash',
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
          ],
          'usage': {
            'prompt_tokens': 1200,
            'completion_tokens': 42,
            'total_tokens': 1242,
          },
        });
        final sse = Stream.fromIterable([
          'data: $payload\n\n',
          'data: $done\n\n',
        ]);
        return http.StreamedResponse(
          sse.transform(utf8.encoder),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final fake = FakeStreamFunction([]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          // The engine makes the BOOT read the sqlite variant; disabling the
          // sqlite scope mid-session flips the variant — the swap this test
          // exercises.
          sqliteEngine: const Sqlite3Engine(),
          visionResolver: () async => InspectImageConfig(
            modelId: 'glm-5.3-flash',
            apiKey: '[REDACTED:Sensitive-Value]',
            baseUrl: 'https://api.example.com/v1',
            httpClient: client,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();
      await waitForIt(() => cli.agent.state.tools.isNotEmpty);
      AgentTool readOf() => cli.agent.state.tools
          .whereType<AgentTool>()
          .firstWhere((t) => t.name == 'read');
      expect(readOf().description, contains(readSqliteSectionPrompt));
      // The flip: the availability refresh swaps the registered read tool.
      io.sendLine('/tools disable sqlite');
      await waitForIt(
        () => !readOf().description.contains(readSqliteSectionPrompt),
        reason: 'the sqlite swap rebuilt the read tool',
      );
      await readOf().execute({'path': '/work/shot.png'}, null, null);
      expect(calls, 1);
      io.sendLine('/stats');
      await waitForIt(() => io.out.toString().contains('total tokens:'));
      io.sendLine('/exit');
      await run;
      expect(
        io.out.toString(),
        contains('total tokens: 1242'),
        reason:
            'the auto-route spend must join /cost through the default sink '
            'even after the sqlite swap rebuilt the read tool',
      );
    },
  );

  test('gh-1984: inspect_image follows the LIVE vision slot (not the boot '
      'config)', () async {
    // Boot with no vision config but a LIVE resolver that serves: the
    // capability decision must consult the same live source the read
    // auto-route rides — a mid-session slot set must not leave /tools
    // claiming "no vision model configured" while the auto-route works,
    // nor the AC3 note name a tool that is not registered.
    var slotServes = true;
    final fake = FakeStreamFunction([]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        // No boot visionConfig — the resolver IS the capability.
        visionResolver: () async => slotServes
            ? InspectImageConfig(
                modelId: 'glm-5.3-flash',
                apiKey: '[REDACTED:Sensitive-Value]',
              )
            : null,
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    await waitForIt(() => cli.agent.state.tools.isNotEmpty);
    // The /tools output accumulates; count the listings before reading the
    // LAST one so a slow flush never reads a stale row.
    int inspectLines() => io.out
        .toString()
        .split('\n')
        .where((l) => l.startsWith('inspect_image'.padRight(16)))
        .length;
    String lastInspectLine() => io.out
        .toString()
        .split('\n')
        .lastWhere((l) => l.startsWith('inspect_image'.padRight(16)));
    io.sendLine('/tools');
    await waitForIt(() => inspectLines() >= 1);
    expect(
      lastInspectLine(),
      contains(' on '),
      reason: 'the live resolver serves a vision config — /tools must say so',
    );
    expect(
      cli.agent.state.tools.whereType<AgentTool>().map((t) => t.name),
      contains('inspect_image'),
      reason: 'the tool registers so the AC3 note can name it truthfully',
    );

    // The slot is withdrawn mid-session (e.g. /models remove vision): the
    // next availability rebuild reflects it live.
    slotServes = false;
    io.sendLine('/tools reload');
    await waitForIt(() => io.out.toString().contains('availability reloaded'));
    io.sendLine('/tools');
    await waitForIt(() => inspectLines() >= 2);
    expect(lastInspectLine(), contains(' off '));
    expect(
      cli.agent.state.tools.whereType<AgentTool>().map((t) => t.name),
      isNot(contains('inspect_image')),
    );

    // And it comes back live too.
    slotServes = true;
    io.sendLine('/tools reload');
    await waitForIt(
      () => io.out.toString().split('availability reloaded').length >= 3,
    );
    io.sendLine('/tools');
    await waitForIt(() => inspectLines() >= 3);
    expect(lastInspectLine(), contains(' on '));
    expect(
      cli.agent.state.tools.whereType<AgentTool>().map((t) => t.name),
      contains('inspect_image'),
    );
    io.sendLine('/exit');
    await run;
  });
}
