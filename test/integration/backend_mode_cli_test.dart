/// Backend agent mode E2E (issue #155): boots the REAL `bin/fah.dart`
/// binary as a subprocess against the mock LLM and pins the wire contract
/// a Go supervisor consumes:
///
/// - `--output events`: stdout is pure JSONL (header first, turn_done
///   last), prose never leaks to stdout; without the flag stdout stays
///   prose (REG).
/// - `--version --output json`: machine-readable version + HEP version.
/// - `--attach`: the photo rides the first request as a base64 data URI.
/// - SIGTERM mid-turn: graceful abort — `cancelled` frame, resumable
///   session JSONL, exit 130.
/// - unknown `--session` key on a clean root: a fresh session, never
///   another session's file.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 8))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:fa_llm_mock/fa_llm_mock.dart';

void main() {
  late Directory tempHome;
  late Directory workspace;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('backend_mode_home_');
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('approvalMode: yolo\n');
    workspace = Directory.systemTemp.createTempSync('backend_mode_ws_');
  });

  tearDown(() {
    tempHome.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  Map<String, String> envOf() => {
    'OPENAI_API_KEY': 'mock',
    'HOME': tempHome.path,
  };

  /// Spawns the real CLI headless with [extraArgs] before the prompt.
  Future<ProcessResult> runFah(MockLlmServer server, List<String> extraArgs) {
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
      environment: envOf(),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(minutes: 6));
  }

  /// Starts the CLI as a live process (for signal tests).
  Future<Process> startFah(
    String baseUrl,
    List<String> extraArgs, {
    String prompt = 'hi',
  }) {
    return Process.start(
      'dart',
      [
        'bin/fah.dart',
        '--provider',
        'openai-completions',
        '--base-url',
        baseUrl,
        '--model',
        'mock-model',
        '--cwd',
        workspace.path,
        ...extraArgs,
        '-p',
        prompt,
      ],
      workingDirectory: Directory.current.path,
      environment: envOf(),
    );
  }

  List<String> jsonlLines(String stdoutText) =>
      stdoutText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  test('--output events: stdout is pure JSONL, header first, turn_done last',
      () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server
      ..enqueueToolCall('bash', '{"command": "echo events-proof"}')
      ..enqueueText('all done');

    final result = await runFah(server, ['--output', 'events']);
    expect(result.exitCode, 0, reason: '${result.stderr}');

    final lines = jsonlLines(result.stdout as String);
    expect(lines, isNotEmpty);
    final frames = <Map<String, dynamic>>[];
    for (final line in lines) {
      frames.add(jsonDecode(line) as Map<String, dynamic>);
    }
    expect(frames.first['type'], 'hep_header');
    expect(frames.first['hep'], 'v1');
    expect(frames.first['fah'], isNotNull);
    expect(frames.first['session'], isNotNull);
    expect(frames.last['type'], 'turn_done');
    expect(frames.last['message'], 'all done');
    // Tool execution surfaced as frames, never prose on stdout.
    expect(
      frames.map((f) => f['type']),
      containsAllInOrder(['agent_start', 'tool_start', 'turn_done']),
    );
    expect(result.stdout as String, isNot(contains('[bash]')));
  });

  test('REG: without --output stdout stays human prose', () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server.enqueueText('plain reply');

    final result = await runFah(server, const []);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final stdout = result.stdout as String;
    expect(stdout, contains('plain reply'));
    expect(jsonlLines(stdout), isNot(contains('hep_header')));
  });

  test('--version --output json is machine-readable', () async {
    final result = await Process.run(
      'dart',
      ['run', 'bin/fah.dart', '--version', '--output', 'json'],
      workingDirectory: Directory.current.path,
      environment: envOf(),
    ).timeout(const Duration(minutes: 4));
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final decoded = jsonDecode((result.stdout as String).trim());
    expect(decoded, isA<Map<String, dynamic>>());
    final map = decoded as Map<String, dynamic>;
    expect(map['version'], isA<String>());
    expect(map['hep'], 'v1');
  });

  test('--attach rides the photo as a base64 data URI in the request',
      () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server.enqueueText('seen it');

    // A minimal PNG (magic bytes + IHDR filler) — the attach path sniffs
    // the type from magic bytes, not the extension.
    final png = File('${workspace.path}/photo.bin')
      ..writeAsBytesSync([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13]);

    final result = await runFah(server, [
      '--attach',
      png.path,
      '--output',
      'events',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');

    expect(server.chatBodies, hasLength(1));
    final body = jsonDecode(server.chatBodies.single) as Map<String, dynamic>;
    final messages = body['messages'] as List;
    final user = messages.firstWhere((m) => (m as Map)['role'] == 'user')
        as Map<String, dynamic>;
    final content = user['content'];
    // OpenAI wire format: array of typed parts.
    expect(content, isA<List>());
    final imagePart = (content as List).firstWhere(
      (part) => (part as Map)['type'] == 'image_url',
      orElse: () => throw 'no image part in request: $content',
    ) as Map<String, dynamic>;
    final url = (imagePart['image_url'] as Map)['url'] as String;
    expect(url, startsWith('data:image/png;base64,'));
  });

  test('--attach of a non-image file passes through as a path reference',
      () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server.enqueueText('read it');

    // Not sniffable as png/jpeg/gif/webp: no magic bytes. Must NOT ride
    // the request as an application/octet-stream image block — it passes
    // through as a path reference the agent opens with its tools.
    final notes = File('${workspace.path}/notes.dat')
      ..writeAsStringSync('plain payload');

    final result = await runFah(server, [
      '--attach',
      notes.path,
      '--output',
      'events',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');

    expect(server.chatBodies, hasLength(1));
    final body = jsonDecode(server.chatBodies.single) as Map<String, dynamic>;
    final messages = body['messages'] as List;
    final user = messages.firstWhere((m) => (m as Map)['role'] == 'user')
        as Map<String, dynamic>;
    final content = user['content'];
    // With no image blocks the prompt rides as a plain string; typed
    // parts appear only once an image block joins the message.
    final text = content is String
        ? content
        : (content as List)
              .where((part) => (part as Map)['type'] == 'text')
              .map((part) => part['text'] as String)
              .join('\n');
    expect(text, contains('[attached file: ${notes.absolute.path}'));
    expect(text, contains('read it with your tools]'));
    // No binary image block was sent for the unknown mime.
    if (content is List) {
      expect(
        content.where((part) => (part as Map)['type'] == 'image_url'),
        isEmpty,
      );
    }
  });

  test('SIGTERM mid-turn: cancelled frame, resumable JSONL, exit 130',
      () async {
    // An inline one-shot server that accepts the chat request and HOLDS
    // the response open — the turn is mid-flight when SIGTERM lands.
    final holder = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => holder.close(force: true));
    final gotRequest = Completer<void>();
    late StreamSubscription sub;
    sub = holder.listen((request) async {
      if (request.uri.path.endsWith('/models')) {
        // Model-cache warm-up: answer so the run can start.
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"object":"list","data":[{"id":"mock-model","object":"model"}]}',
        );
        await request.response.close();
        return;
      }
      if (!gotRequest.isCompleted) gotRequest.complete();
      // Hold forever; the abort path cancels the client connection.
      await request.drain<void>();
      try {
        await request.response.flush();
      } catch (_) {}
    });
    addTearDown(() => sub.cancel());

    final process = await startFah(
      'http://127.0.0.1:${holder.port}/v1',
      ['--output', 'events'],
    );
    final stdoutBuffer = StringBuffer();
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuffer.write);

    await gotRequest.future.timeout(const Duration(minutes: 2));
    // The request is in flight: kill with SIGTERM.
    process.kill(ProcessSignal.sigterm);

    final exitCode = await process.exitCode.timeout(
      const Duration(minutes: 2),
    );
    await stdoutSub.cancel();

    expect(exitCode, 130);
    final lines = jsonlLines(stdoutBuffer.toString());
    final frames = [
      for (final line in lines) jsonDecode(line) as Map<String, dynamic>,
    ];
    expect(frames.first['type'], 'hep_header');
    expect(frames.last['type'], 'cancelled');
    // No terminal frame after cancelled.
    expect(
      frames.sublist(0, frames.length - 1).map((f) => f['type']),
      isNot(contains('turn_done')),
    );

    // The session JSONL is resumable: one file, every line parses.
    final sessionFiles = <File>[
      for (final entity in Directory('${tempHome.path}/.fah/sessions')
          .listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.jsonl')) entity,
    ];
    expect(sessionFiles, hasLength(1));
    final sessionLines = sessionFiles.single
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    expect(sessionLines, isNotEmpty);
    for (final line in sessionLines) {
      expect(() => jsonDecode(line), returnsNormally,
          reason: 'session JSONL must stay parseable mid-abort: $line');
    }
  });

  test('unknown --session key on a clean root starts a fresh session',
      () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server.enqueueText('fresh answer');

    final sessionsRoot = Directory('${tempHome.path}/.fah/sessions');
    expect(sessionsRoot.existsSync(), isFalse);

    final result = await runFah(server, ['--session', 'backend-key-42']);
    expect(result.exitCode, 0, reason: '${result.stderr}');

    final files = <File>[
      for (final entity in sessionsRoot.listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.jsonl')) entity,
    ];
    // Exactly one fresh session — never zero, never someone else's.
    expect(files, hasLength(1));
    // A session_info record carries the name the key asked for.
    final records = [
      for (final line in files.single.readAsLinesSync())
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ];
    final info = records.firstWhere(
      (r) => r['type'] == 'session_info',
      orElse: () => throw 'no session_info record in session file',
    );
    expect(info['name'], 'backend-key-42');
  });
}
