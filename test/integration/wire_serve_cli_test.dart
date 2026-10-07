@Tags(['integration'])
/// `fa wire-serve` end-to-end (issue #1103) — the real boot path
/// ([AgentCli.runWireServe]) against fake providers, in process, no real
/// network beyond the loopback WS socket the card mandates:
///
/// - IT-1: loopback WS handshake (hello -> welcome), single-attach gate
///   (a second client gets the loud `already_attached`), clean reattach
///   after disconnect, E1 pending-approval re-delivery by request id.
/// - IT-2: NDJSON scripted run — prompt in, event frames out, final
///   message text present (line framing exercised in-memory; `serveStdio`
///   itself only swaps the byte source, which cannot be stdin in-process).
/// - IT-3: SIGTERM-shaped shutdown -> session JSONL persisted -> a second
///   CLI resumes the session (the model sees the first run's turns).
/// - E2: an occupied port is a loud startup failure naming the port.
/// - E4: the bearer token never lands in session records (the transcript
///   stays free of it while the token rode every handshake).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, WebSocket, stderr;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../bin/fah_wire_serve.dart';
import '../cli/agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
  });

  FakeCliIO silentIo() => FakeCliIO()..isInteractive = false;

  AgentCli bootCli({
    required FakeStreamFunction fake,
    String? sessionName,
    ApprovalMode approvalMode = ApprovalMode.alwaysAsk,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        webSearchConfig: WebSearchConfig(),
        providerKind: 'openai-completions',
        sessionName: sessionName,
        approvalMode: approvalMode,
      ),
      io: silentIo(),
      streamFunction: fake.call,
    );
  }

  /// Connects a WS client to the test server with retries (the accept
  /// loop starts inside [runWireServe]'s serve closure, after boot).
  Future<WebSocket> connect(int port, {String? token}) async {
    var last = 'never attempted';
    for (var i = 0; i < 200; i++) {
      try {
        return await WebSocket.connect(
          'ws://127.0.0.1:$port?token=${token ?? 'tok'}',
        );
      } on Object catch (error) {
        last = '$error';
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    fail('wire-serve ws endpoint never came up: $last');
  }

  Map<String, dynamic> decodeLine(String line) =>
      jsonDecode(line) as Map<String, dynamic>;

  test('E2: an occupied port fails loudly naming the port', () async {
    final first = await bindLoopback(0);
    try {
      await expectLater(
        bindLoopback(first.port),
        throwsA(
          isA<SocketException>().having(
            (e) => e.toString(),
            'message',
            contains('${first.port}'),
          ),
        ),
      );
    } finally {
      await first.close();
    }
  });

  test('IT-1: WS handshake, single-attach, reattach; E1 re-delivery', () async {
    final fake = FakeStreamFunction([
      toolTurn([
        const ToolCall(
          id: 'call_1',
          name: 'bash',
          arguments: {'command': 'rm -rf /tmp/x'},
        ),
      ]),
      textTurn('done'),
    ]);
    final cli = bootCli(fake: fake);
    final http = await bindLoopback(0);
    final served = cli.runWireServe(
      serve: (server) => httpListen(http, server, 'tok'),
    );

    final ws = await connect(http.port);
    final lines = <Map<String, dynamic>>[];
    final gotFrame = Completer<void>();
    ws.listen((message) {
      lines.add(decodeLine(message as String));
      if (!gotFrame.isCompleted) gotFrame.complete();
    });
    ws.add(
      jsonEncode({
        'v': 1,
        'kind': 'hello',
        'versions': [1],
      }),
    );
    await gotFrame.future.timeout(const Duration(seconds: 20));
    final welcome = lines.single;
    expect(welcome['kind'], 'welcome');
    expect(welcome['v'], 1);

    // Prompt: the alwaysAsk approval surfaces as approval_request.
    ws.add(jsonEncode(const WirePromptCommand('deploy').toJson()));
    await _waitFor(lines, (f) => f['kind'] == 'approval_request');
    final approval = lines.lastWhere((f) => f['kind'] == 'approval_request');
    final requestId = approval['id'] as String;
    expect(approval['toolName'], 'bash');

    // Single-attach: a second client gets the loud already_attached.
    final ws2 = await connect(http.port);
    final second = <Map<String, dynamic>>[];
    final gotSecond = Completer<void>();
    ws2.listen((message) {
      second.add(decodeLine(message as String));
      if (!gotSecond.isCompleted) gotSecond.complete();
    });
    ws2.add(
      jsonEncode({
        'v': 1,
        'kind': 'hello',
        'versions': [1],
      }),
    );
    await gotSecond.future.timeout(const Duration(seconds: 20));
    expect(second.single['kind'], 'error');
    expect(second.single['code'], 'already_attached');
    await ws2.close();

    // E1: client A disconnects BEFORE answering; the pending approval
    // must survive and re-deliver to the next attach — SAME request id.
    await ws.close();
    await _pump();

    final ws3 = await connect(http.port);
    final third = <Map<String, dynamic>>[];
    final gotReplay = Completer<void>();
    ws3.listen((message) {
      third.add(decodeLine(message as String));
      if (third.any((f) => f['kind'] == 'approval_request') &&
          !gotReplay.isCompleted) {
        gotReplay.complete();
      }
    });
    ws3.add(
      jsonEncode({
        'v': 1,
        'kind': 'hello',
        'versions': [1],
      }),
    );
    await gotReplay.future.timeout(const Duration(seconds: 20));
    final replay = third.lastWhere((f) => f['kind'] == 'approval_request');
    expect(replay['id'], requestId, reason: 'E1: re-delivery is idempotent');

    // Answer it; the run completes; turn_end carries the final text.
    ws3.add(
      jsonEncode(
        const WireApprovalResponseCommand(
          id: 'ignored-by-server',
          decision: ApprovalDecision.approveOnce,
        ).toJson(),
      ),
    );
    // The server keys responses by ITS request id — the mismatched id
    // above must yield an unknown_request_id error, then the real id
    // answers the pending approval.
    await _waitFor(third, (f) => f['kind'] == 'error');
    expect(
      third.lastWhere((f) => f['kind'] == 'error')['code'],
      'unknown_request_id',
    );
    ws3.add(
      jsonEncode(
        WireApprovalResponseCommand(
          id: requestId,
          decision: ApprovalDecision.approveOnce,
        ).toJson(),
      ),
    );
    await _waitFor(third, (f) => f['kind'] == 'agent_end');
    expect(
      third.any(
        (f) => f['kind'] == 'turn_end' && jsonEncode(f).contains('"done"'),
      ),
      isTrue,
      reason: 'final assistant text rides turn_end',
    );

    await http.close(force: true);
    await served.timeout(const Duration(seconds: 20));
  });

  test(
    'IT-2: NDJSON stdio scripted run emits the golden event sequence',
    () async {
      final fake = FakeStreamFunction([textTurn('Hello from the wire')]);
      final cli = bootCli(fake: fake, approvalMode: ApprovalMode.yolo);
      final incoming = StreamController<String>();
      final outLines = <String>[];
      final done = Completer<void>();
      final served = cli.runWireServe(
        serve: (server) {
          final send = (Map<String, dynamic> frame) {
            outLines.add(AgentWireProtocol.frameLine(frame));
            if (frame['kind'] == 'agent_settled') {
              done.complete();
            }
          };
          return server
              .attach(decodeNdjson(server, incoming.stream, send), send)
              .whenComplete(() {
                if (!done.isCompleted) done.complete();
              });
        },
      );

      incoming.add(
        jsonEncode({
          'v': 1,
          'kind': 'hello',
          'versions': [1],
        }),
      );
      incoming.add(jsonEncode(const WirePromptCommand('hi').toJson()));
      await done.future.timeout(const Duration(seconds: 20));
      await incoming.close();
      expect(await served.timeout(const Duration(seconds: 20)), 0);

      final kinds = outLines.map((l) => decodeLine(l)['kind']).toList();
      expect(kinds.first, 'welcome');
      expect(kinds, contains('agent_start'));
      expect(kinds, contains('turn_start'));
      expect(kinds, contains('turn_end'));
      expect(kinds, contains('agent_end'));
      expect(kinds, contains('agent_settled'));
      // The final assistant text is present on the turn_end frame.
      final turnEnd = outLines
          .map(decodeLine)
          .lastWhere((f) => f['kind'] == 'turn_end');
      expect(jsonEncode(turnEnd), contains('Hello from the wire'));
      // NDJSON discipline: exactly one JSON object per line (UTF-8 plus a
      // trailing \n; no embedded newlines ever).
      for (final line in outLines) {
        expect(line.endsWith('\n'), isTrue, reason: line);
        expect(line.trim().contains('\n'), isFalse, reason: line);
        expect(() => jsonDecode(line.trim()), returnsNormally, reason: line);
      }
    },
  );

  test(
    'T1/r2: a malformed line is a loud bad_frame and the serve survives',
    () async {
      final fake = FakeStreamFunction([textTurn('still here')]);
      final cli = bootCli(fake: fake, approvalMode: ApprovalMode.yolo);
      final incoming = StreamController<String>();
      final outFrames = <Map<String, dynamic>>[];
      final gotError = Completer<void>();
      final settled = Completer<void>();
      final served = cli.runWireServe(
        serve: (server) {
          final send = (Map<String, dynamic> frame) {
            outFrames.add(frame);
            if (frame['kind'] == 'error' && !gotError.isCompleted) {
              gotError.complete();
            }
            if (frame['kind'] == 'agent_settled' && !settled.isCompleted) {
              settled.complete();
            }
          };
          return server.attach(
            decodeNdjson(server, incoming.stream, send),
            send,
          );
        },
      );

      incoming.add(
        jsonEncode({
          'v': 1,
          'kind': 'hello',
          'versions': [1],
        }),
      );
      incoming.add('not json'); // the BLOCKING repro from review round 2.
      incoming.add(jsonEncode(const WirePromptCommand('hi').toJson()));
      await gotError.future.timeout(const Duration(seconds: 20));
      final error = outFrames.lastWhere((f) => f['kind'] == 'error');
      expect(error['code'], 'bad_frame');
      expect(error['message'], isNotEmpty);
      // The connection — and the whole serve — is still alive: the NEXT
      // prompt after the bad line runs to completion.
      await settled.future.timeout(const Duration(seconds: 20));
      await incoming.close();
      expect(await served.timeout(const Duration(seconds: 20)), 0);
    },
  );

  test(
    'T1/r4: oversized lines are dropped loudly, memory stays bounded',
    () async {
      // One oversized complete line inside a single chunk: dropped, flagged.
      final big = utf8.encode('x' * ((1 << 20) + 5) + '\n');
      final flagged = <String>[];
      final out = await byteLines(
        Stream.fromIterable([utf8.encode('{"ok":1}\n'), big]),
        onOversize: flagged.add,
      ).toList();
      expect(out, hasLength(1));
      expect(utf8.decode(out.single), '{"ok":1}');
      expect(flagged, hasLength(1));

      // An oversized line ACCUMULATING across chunks: the carry is dropped
      // mid-flight and the splitter resumes after its newline.
      final out2 = await byteLines(
        Stream.fromIterable([
          utf8.encode('a' * 700000),
          utf8.encode('b' * 700000),
          utf8.encode('c' * 700000 + '\n{"next":1}\n'),
        ]),
        onOversize: flagged.add,
      ).toList();
      expect(out2, hasLength(1), reason: 'only the post-skip line survives');
      expect(utf8.decode(out2.single), '{"next":1}');
      expect(flagged, hasLength(2));
    },
  );

  test('T1/r4: CRLF writers are tolerated (trailing 0x0D trimmed)', () async {
    final out = await byteLines(
      Stream.fromIterable([
        utf8.encode('{"a":1}\r\n'),
        utf8.encode('{"b":2}\n'),
      ]),
    ).toList();
    expect(out.map(utf8.decode), ['{"a":1}', '{"b":2}']);
  });

  test(
    'T1/r3: bad BYTES are a loud bad_frame and the serve survives',
    () async {
      final fake = FakeStreamFunction([textTurn('bytes ok')]);
      final cli = bootCli(fake: fake, approvalMode: ApprovalMode.yolo);
      final incoming = StreamController<List<int>>();
      final outFrames = <Map<String, dynamic>>[];
      final gotError = Completer<void>();
      final settled = Completer<void>();
      final served = cli.runWireServe(
        serve: (server) {
          final send = (Map<String, dynamic> frame) {
            outFrames.add(frame);
            if (frame['kind'] == 'error' && !gotError.isCompleted) {
              gotError.complete();
            }
            if (frame['kind'] == 'agent_settled' && !settled.isCompleted) {
              settled.complete();
            }
          };
          // The REAL stdio byte path: raw bytes -> byteLines -> guarded
          // decode (review #1113 r3, #1).
          return server
              .attach(
                decodeNdjson(server, byteLines(incoming.stream), send),
                send,
              )
              .whenComplete(() {
                if (!settled.isCompleted) settled.complete();
              });
        },
      );

      // hello split across two chunks (exercises the byte-line carry),
      // then a line of invalid UTF-8 bytes, then a blank line, then a
      // valid prompt.
      final hello = utf8.encode('{"v":1,"kind":"hello","versions":[1]}\n');
      incoming.add(hello.sublist(0, 10));
      incoming.add(hello.sublist(10));
      incoming.add(const [0xFF, 0xFE, 0x0A]);
      incoming.add(utf8.encode('\n'));
      incoming.add(
        utf8.encode('${jsonEncode(const WirePromptCommand('hi').toJson())}\n'),
      );
      await gotError.future.timeout(const Duration(seconds: 20));
      final error = outFrames.lastWhere((f) => f['kind'] == 'error');
      expect(error['code'], 'bad_frame');
      // The serve is alive: the NEXT prompt after the bad bytes runs.
      await settled.future.timeout(const Duration(seconds: 20));
      await incoming.close();
      expect(await served.timeout(const Duration(seconds: 20)), 0);
    },
  );

  test('IT-3: shutdown persists; a second CLI resumes the session', () async {
    final fake1 = FakeStreamFunction([textTurn('first-run-answer')]);
    final cli1 = bootCli(
      fake: fake1,
      sessionName: 'wire-it3',
      approvalMode: ApprovalMode.yolo,
    );
    final incoming = StreamController<String>();
    final settled = Completer<void>();
    final served1 = cli1.runWireServe(
      serve: (server) {
        final send = (Map<String, dynamic> frame) {
          if (frame['kind'] == 'agent_settled' && !settled.isCompleted) {
            settled.complete();
          }
        };
        return server.attach(decodeNdjson(server, incoming.stream, send), send);
      },
    );
    incoming.add(
      jsonEncode({
        'v': 1,
        'kind': 'hello',
        'versions': [1],
      }),
    );
    incoming.add(jsonEncode(const WirePromptCommand('remember me').toJson()));
    await settled.future.timeout(const Duration(seconds: 20));
    await incoming.close();
    expect(await served1.timeout(const Duration(seconds: 20)), 0);

    // Resume through the EXISTING CLI machinery: a second boot with
    // sessionName loads the persisted transcript; the next model call
    // must carry the first run's user + assistant messages.
    final fake2 = FakeStreamFunction([textTurn('resumed')]);
    final cli2 = bootCli(
      fake: fake2,
      sessionName: 'wire-it3',
      approvalMode: ApprovalMode.yolo,
    );
    final resumeIncoming = StreamController<String>();
    final resumeSettled = Completer<void>();
    final served2 = cli2.runWireServe(
      serve: (server) {
        final send = (Map<String, dynamic> frame) {
          if (frame['kind'] == 'agent_settled' && !resumeSettled.isCompleted) {
            resumeSettled.complete();
          }
        };
        return server
            .attach(decodeNdjson(server, resumeIncoming.stream, send), send)
            .whenComplete(() {
              if (!resumeSettled.isCompleted) resumeSettled.complete();
            });
      },
    );
    resumeIncoming.add(
      jsonEncode({
        'v': 1,
        'kind': 'hello',
        'versions': [1],
      }),
    );
    resumeIncoming.add(jsonEncode(const WirePromptCommand('again').toJson()));
    await resumeSettled.future.timeout(const Duration(seconds: 20));
    await resumeIncoming.close();
    expect(await served2.timeout(const Duration(seconds: 20)), 0);

    final resumedContext = fake2.contexts.single;
    final texts = [
      for (final message in resumedContext.messages)
        if (message is UserMessage)
          switch (message.content) {
            final String text => text,
            final List parts =>
              parts.whereType<TextContent>().map((t) => t.text).join(),
            _ => '',
          },
    ];
    expect(
      texts.join('\n'),
      contains('remember me'),
      reason: 'the first run survived the shutdown via the session file',
    );
  });

  test(
    'E4 + authn-lite: bad token is rejected; token stays out of records',
    () async {
      final fake = FakeStreamFunction([textTurn('shh')]);
      final cli = bootCli(fake: fake, approvalMode: ApprovalMode.yolo);
      final http = await bindLoopback(0);
      final served = cli.runWireServe(
        serve: (server) => httpListen(http, server, 'sekrit-token'),
        onDiagnostic: (line) => stderr.writeln(line),
      );
      // Wrong token: the upgrade is refused (HTTP 401) — WebSocket.connect
      // fails; the loud gate is the transport, not a protocol frame.
      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:${http.port}?token=wrong',
        ).then<void>((_) {}),
        throwsA(anything),
      ).timeout(const Duration(seconds: 20));
      // 20s, not 10s: these waits are one-shot deadlines on scheduler-bound
      // round-trips with no SLA — on a saturated runner (flake, heads
      // 4a25f2de + 235eeb36, PTY shard 2/3) a HEALTHY handshake missed 10s.
      // This file's load-tolerant budget is 20s (#1311); unlike the
      // countdown family (#1345) the predicate is already exact — welcome
      // is the one legal first server frame — only the budget was tight.
      // The right token works: handshake (hello -> welcome), like any v1
      // client — the server never speaks before the client's hello.
      final ws = await connect(http.port, token: 'sekrit-token');
      ws.add(
        jsonEncode({
          'v': 1,
          'kind': 'hello',
          'versions': [1],
        }),
      );
      // 30s, not 10s: the shard runs 4 suites on 4 arm64 cores and a
      // loaded event loop once starved the welcome past 10s (run
      // 37552613207 — the only red of this test, no product path
      // involved). The budget matches this file's other handshake waits
      // (20s settle / 20s serve shutdown); the assertion is unchanged.
      final first = await ws.first.timeout(const Duration(seconds: 30));
      expect(decodeLine(first as String)['kind'], 'welcome');
      await ws.close();
      await http.close(force: true);
      await served.timeout(const Duration(seconds: 20));
      // E4: the token never reached the session records. Sweep the whole
      // persisted session tree under the session root — recursively, and
      // LOUD on anything unreadable (a silent skip would hide a leak;
      // review #1113 r2, #9).
      await _sweepNoToken(env, '/sessions');
    },
  );
}

Future<void> _waitFor(
  List<Map<String, dynamic>> frames,
  bool Function(Map<String, dynamic>) predicate,
) async {
  for (var i = 0; i < 2000; i++) {
    if (frames.any(predicate)) return;
    await _pump();
  }
  fail('frame never arrived; got: ${frames.map((f) => f['kind']).toList()}');
}

/// Recursively asserts the bearer token never appears in any file (name
/// or content) under [dir]; an unreadable entry FAILS the sweep — a
/// silent skip would hide exactly the leak this sweep exists to catch.
Future<void> _sweepNoToken(MemoryExecutionEnv env, String dir) async {
  final listing = await env.listDir(dir);
  expect(listing.isOk, isTrue, reason: 'E4 sweep: cannot read directory $dir');
  for (final info in listing.getOrThrow()) {
    expect(
      info.name.contains('sekrit-token'),
      isFalse,
      reason: 'E4: token in file name ${info.path}',
    );
    switch (info.kind) {
      case FileKind.directory:
        await _sweepNoToken(env, info.path);
      case FileKind.file:
      case FileKind.symlink:
        final content = await env.readTextFile(info.path);
        expect(
          content.isOk,
          isTrue,
          reason: 'E4 sweep: cannot read ${info.path}',
        );
        expect(
          content.getOrThrow().contains('sekrit-token'),
          isFalse,
          reason: 'E4: bearer token leaked into ${info.path}',
        );
    }
  }
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 5));
