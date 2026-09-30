// TEMPORARY review-verification scratch — deleted after the review run.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/wire/wire_protocol.dart';
import 'package:flutter_agent_harness/src/wire/wire_serve.dart';
import 'package:test/test.dart';

// Mirror of bin/fah_wire_serve.dart decodeNdjson (the production chain).
Stream<Map<String, dynamic>> decodeNdjsonMirror(
  WireServeServer server,
  Stream<String> lines,
  void Function(Map<String, dynamic>) send,
) =>
    lines.map((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return null;
      try {
        return AgentWireProtocol.parseLine(trimmed);
      } on FormatException catch (e) {
        server.protocolError('bad_frame', '$e', send);
        return null;
      } on WireProtocolException catch (e) {
        server.protocolError('bad_frame', '$e', send);
        return null;
      }
    }).where((f) => f != null).cast<Map<String, dynamic>>();

// The EXACT serveStdio shape: bytes -> utf8.decoder -> LineSplitter -> decodeNdjson.
Stream<Map<String, dynamic>> stdioChain(
  WireServeServer server,
  Stream<List<int>> bytes,
  void Function(Map<String, dynamic>) send,
) =>
    decodeNdjsonMirror(
      server,
      bytes.transform(utf8.decoder).transform(const LineSplitter()),
      send,
    );

WireServeServer server() => WireServeServer(
      runPrompt: (_) async {},
      steer: (_) {},
      abort: () {},
      isBusy: () => false,
    );

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  test('SCRATCH 1: garbage line through the decode chain stays alive',
      () async {
    final sent = <Map<String, dynamic>>[];
    final srv = server();
    final incoming = StreamController<String>();
    final done = srv.attach(
      decodeNdjsonMirror(srv, incoming.stream, sent.add),
      sent.add,
    );
    incoming.add('not json');
    await pump();
    incoming.add('{"v":1,"kind":"hello","versions":[1]}');
    await pump();
    // ignore: avoid_print
    print(
      'S1 frames=${sent.map((f) => f['kind'] == 'error' ? f['code'] : f['kind']).toList()} '
      'attached=${srv.attached}',
    );
    await incoming.close();
    await done;
  });

  test('SCRATCH 2: invalid UTF-8 byte on stdin — the byte-level hole',
      () async {
    final sent = <Map<String, dynamic>>[];
    final srv = server();
    final incoming = StreamController<List<int>>();
    final done = srv.attach(
      stdioChain(srv, incoming.stream, sent.add),
      sent.add,
    );
    // Valid hello first.
    incoming.add(utf8.encode('{"v":1,"kind":"hello","versions":[1]}\n'));
    await pump();
    final attachedBefore = srv.attached;
    // One invalid byte (as a pipe/terminal can emit).
    incoming.add([0xFF, 0x0A]);
    await pump();
    await pump();
    // Then a perfectly valid prompt line.
    incoming.add(utf8.encode('{"v":1,"kind":"prompt","text":"x"}\n'));
    await pump();
    // ignore: avoid_print
    print(
      'S2 attachedBefore=$attachedBefore attachedAfter=${srv.attached} '
      'framesAfterBadByte=${sent.map((f) => f['kind'] == 'error' ? f['code'] : f['kind']).skip(1).toList()}',
    );
    await incoming.close();
    await done.timeout(const Duration(seconds: 2), onTimeout: () {});
  });

  test('SCRATCH 3: request issued AFTER shutdown() never resolves', () async {
    final srv = server();
    await srv.shutdown();
    var wedged = true;
    final outcome = await srv
        .approvalPrompt(
          const ApprovalRequest(
            toolName: 'bash',
            tier: ApprovalTier.exec,
            arguments: {},
            reason: 'late tool call during teardown',
          ),
        )
        .timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            wedged = true;
            return ApprovalDecision.deny;
          },
        );
    wedged = wedged && srv.pendingRequestIds.isNotEmpty;
    // ignore: avoid_print
    print(
      'S3 approvalPrompt after shutdown resolved to: $outcome '
      '(wedged-with-unresolvable-pending=$wedged, pending=${srv.pendingRequestIds})',
    );
    expect(srv.pendingRequestIds, isNotEmpty,
        reason: 'a post-shutdown request stays registered forever');
  });
}
