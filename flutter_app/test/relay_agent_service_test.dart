// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/services/relay_agent_service.dart';
import 'package:fa_browser_agent/fa_browser_agent.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory `UiPortChannel`: records what the UI sends and lets tests
/// inject SW→UI envelopes, reproducing the port round-trip without a
/// service worker.
final class FakePortChannel implements UiPortChannel {
  final _inbound = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];

  @override
  void send(Map<String, dynamic> json) => sent.add(json);

  @override
  Stream<Map<String, dynamic>> get onMessage => _inbound.stream;

  /// SW → UI: encode and deliver one protocol envelope.
  void fromWorker(UiProtocolMessage message) => _inbound.add(message.encode());

  /// The recorded UI → SW envelope of [kind] (last one wins).
  Map<String, dynamic>? sentOf(String kind) {
    for (final json in sent.reversed) {
      if (json['kind'] == kind) return json;
    }
    return null;
  }

  @override
  void close() {
    if (!_inbound.isClosed) _inbound.close();
  }

  @override
  bool get isClosed => _inbound.isClosed;
}

Future<({RelayAgentService service, FakePortChannel channel})> _attached({
  List<Map<String, dynamic>> replay = const [],
}) async {
  final channel = FakePortChannel();
  final transport = WorkerRelayTransport(
    portFactory: () => channel,
    channel: channel,
  );
  final service = RelayAgentService.forTest(transport);
  final connected = transport.connect();
  // hello → hello_ack(session) → attach → attached(replay)
  await () async {
    while (channel.sentOf('hello') == null) {
      await Future<void>.delayed(Duration.zero);
    }
    channel.fromWorker(
      HelloAckMsg(
        protoVersion: uiProtocolVersion,
        serverCapabilities: const ['stream', 'approvals'],
        sessionId: 'sw-1',
      ),
    );
    while (channel.sentOf('attach') == null) {
      await Future<void>.delayed(Duration.zero);
    }
    channel.fromWorker(AttachedMsg(sessionId: 'sw-1', replay: replay));
  }();
  await connected;
  return (service: service, channel: channel);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('attach replay rebuilds the transcript', () async {
    final (:service, :channel) = await _attached(
      replay: [
        {
          'seq': 1,
          'event': {'type': 'delta', 'text': 'hel'},
        },
        {
          'seq': 2,
          'event': {
            'type': 'message_done',
            'role': 'assistant',
            'text': 'hello from the sw agent',
          },
        },
      ],
    );
    expect(service.relaySessionId, 'sw-1');
    expect(service.messages, hasLength(1));
    expect(service.messages.single.role, 'assistant');
    expect(service.messages.single.content, 'hello from the sw agent');
    addTearDown(channel.close);
  });

  test('sendText sends a prompt and renders the user bubble', () async {
    final (:service, :channel) = await _attached();
    await service.sendText('what do you see?');
    final prompt = channel.sentOf('prompt');
    expect(prompt, isNotNull);
    expect(prompt!['text'], 'what do you see?');
    expect(service.messages.last.role, 'user');
    addTearDown(channel.close);
  });

  test('a live turn steers instead of prompting', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(StreamMsg(event: {'type': 'status', 'running': true}));
    await Future<void>.delayed(Duration.zero); // pump the port listeners
    await service.sendText('stop that, do this');
    expect(channel.sentOf('steer'), isNotNull);
    expect(channel.sentOf('prompt'), isNull);
    expect(service.isStreaming, isTrue);
    addTearDown(channel.close);
  });

  test('stream deltas accumulate into one assistant message', () async {
    final (:service, :channel) = await _attached();
    channel
      ..fromWorker(StreamMsg(event: {'type': 'delta', 'text': 'a'}))
      ..fromWorker(StreamMsg(event: {'type': 'delta', 'text': 'b'}))
      ..fromWorker(
        MessageDoneMsg(message: {'role': 'assistant', 'text': 'ab'}),
      );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages.where((m) => m.role == 'assistant').last.content,
      'ab',
    );
    addTearDown(channel.close);
  });

  test('tool results render collapsed tool messages', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      StreamMsg(
        event: {
          'type': 'tool_result',
          'toolName': 'browser_active_tab',
          'isError': false,
          'text': 'https://example.com',
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final tool = service.messages.last;
    expect(tool.role, 'tool');
    expect(tool.toolName, 'browser_active_tab');
    expect(tool.isError, isFalse);
    addTearDown(channel.close);
  });

  test('approval requests surface through the prompt handler', () async {
    final (:service, :channel) = await _attached();
    final decisions = <ApprovalDecision>[];
    service.approvalPromptHandler = (request) async {
      expect(request.toolName, 'bash');
      expect(request.reason, contains('exec'));
      decisions.add(ApprovalDecision.approveOnce);
      return ApprovalDecision.approveOnce;
    };
    channel.fromWorker(
      ApprovalRequestMsg(
        id: 'ap-1',
        call: {'toolName': 'bash'},
        reason: 'exec tier requires approval',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final response = channel.sentOf('approval_response');
    expect(response, isNotNull);
    expect(response!['id'], 'ap-1');
    expect(response['decision'], 'allow');
    expect(decisions, hasLength(1));
    addTearDown(channel.close);
  });

  test('no approval handler mounted denies conservatively', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      ApprovalRequestMsg(id: 'ap-2', call: {}, reason: 'unattended'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(channel.sentOf('approval_response')!['decision'], 'deny');
    addTearDown(channel.close);
  });

  test('abort cancels the active turn over the wire', () async {
    final (:service, :channel) = await _attached();
    service.abort();
    expect(channel.sentOf('cancel'), isNotNull);
    addTearDown(channel.close);
  });

  test('an empty assistant message gets the placeholder', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      MessageDoneMsg(message: {'role': 'assistant', 'text': ''}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.messages.last.content, faEmptyResponsePlaceholder);
    addTearDown(channel.close);
  });
}

/// The fa_ui placeholder, re-exported for the assertion above.
const faEmptyResponsePlaceholder = emptyResponsePlaceholder;
