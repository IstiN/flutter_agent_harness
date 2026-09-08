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

  test(
    'newSessionAction sends session_new; the attach clears the view',
    () async {
      final (:service, :channel) = await _attached(
        replay: [
          {
            'seq': 1,
            'event': {
              'type': 'message_done',
              'role': 'assistant',
              'text': 'old transcript',
            },
          },
        ],
      );
      expect(service.messages, hasLength(1));
      final reset = service.newSessionAction;
      expect(reset, isNotNull);
      await reset!();
      await Future<void>.delayed(Duration.zero);
      expect(channel.sentOf('session_new'), isNotNull);
      // The SW answers with AttachedMsg(sessionId: fresh, replay: []) — the
      // same rebuild path clears the transcript and adopts the new id.
      channel.fromWorker(const AttachedMsg(sessionId: 'sw-fresh', replay: []));
      await Future<void>.delayed(Duration.zero);
      expect(service.relaySessionId, 'sw-fresh');
      expect(service.messages, isEmpty);
      addTearDown(channel.close);
    },
  );

  test('newSessionAction is null while a turn runs', () async {
    final (:service, :channel) = await _attached();
    await service.sendText('running turn');
    // sendText flipped the optimistic streaming state (async broadcast
    // delivery — pump the queue before asserting).
    await Future<void>.delayed(Duration.zero);
    expect(service.isStreaming, isTrue);
    expect(service.newSessionAction, isNull);
    addTearDown(channel.close);
  });

  test('listSessions returns the SW history over sessions_query', () async {
    final (:service, :channel) = await _attached();
    final future = service.listSessions();
    await Future<void>.delayed(Duration.zero);
    expect(channel.sentOf('sessions_query'), isNotNull);
    channel.fromWorker(
      const SessionsResultMsg(
        sessions: [
          {
            'id': 'live-1',
            'running': true,
            'createdAt': '2026-09-08T11:47:00.000Z',
            'cwd': '/',
          },
          {
            'id': 'arch-1',
            'archived': true,
            'createdAt': '2026-09-07T09:00:00.000Z',
            'cwd': '/',
          },
        ],
      ),
    );
    final sessions = await future;
    expect(sessions, hasLength(2));
    expect(sessions[0].id, 'live-1');
    expect(sessions[0].createdAt.year, 2026);
    expect(sessions[1].metadata?['archived'], isTrue);
    addTearDown(channel.close);
  });

  test('openSessionAction dispatches session_open with the id', () async {
    final (:service, :channel) = await _attached();
    final open = service.openSessionAction;
    expect(open, isNotNull);
    await open!('arch-1');
    await Future<void>.delayed(Duration.zero);
    final msg = channel.sentOf('session_open');
    expect(msg, isNotNull);
    expect(msg!['sessionId'], 'arch-1');
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

  test('thinking deltas render a thinking bubble before the answer', () async {
    final (:service, :channel) = await _attached();
    channel
      ..fromWorker(StreamMsg(event: {'type': 'thinking_delta', 'text': 'hmm '}))
      ..fromWorker(
        StreamMsg(event: {'type': 'thinking_delta', 'text': 'let me see'}),
      )
      ..fromWorker(StreamMsg(event: {'type': 'delta', 'text': 'Answer'}))
      ..fromWorker(
        MessageDoneMsg(message: {'role': 'assistant', 'text': 'Answer'}),
      );
    await Future<void>.delayed(Duration.zero);
    final thinking = service.messages
        .where((m) => m.role == 'thinking')
        .toList();
    expect(thinking, hasLength(1));
    expect(thinking.single.content, 'hmm let me see');
    // Thinking stays out of the assistant text.
    expect(
      service.messages.where((m) => m.role == 'assistant').last.content,
      'Answer',
    );
    addTearDown(channel.close);
  });

  test('a new turn streams thinking into a fresh bubble', () async {
    final (:service, :channel) = await _attached();
    channel
      ..fromWorker(StreamMsg(event: {'type': 'thinking_delta', 'text': 't1'}))
      ..fromWorker(MessageDoneMsg(message: {'role': 'assistant', 'text': 'a1'}))
      ..fromWorker(StreamMsg(event: {'type': 'thinking_delta', 'text': 't2'}))
      ..fromWorker(
        MessageDoneMsg(message: {'role': 'assistant', 'text': 'a2'}),
      );
    await Future<void>.delayed(Duration.zero);
    final thinking = service.messages
        .where((m) => m.role == 'thinking')
        .toList();
    expect(thinking.map((m) => m.content), ['t1', 't2']);
    addTearDown(channel.close);
  });

  test('thinking replays into thinking bubbles on rebuild', () async {
    final (:service, :channel) = await _attached(
      replay: [
        {'type': 'thinking_delta', 'text': 'replayed thought'},
        {'type': 'message_done', 'role': 'assistant', 'text': 'replied'},
      ],
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages.where((m) => m.role == 'thinking').single.content,
      'replayed thought',
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

  test(
    'no approval handler mounted leaves the decision to another client',
    () async {
      // A UI that cannot ask the human must not steal the decision from one
      // that can (a second panel, the e2e driver, a remote attach view): the
      // SW's 120s timeout stays the conservative backstop and denies with a
      // note if nobody answers. An instant bystander deny recorded a denial
      // the user never chose (live e2e regression).
      final (:service, :channel) = await _attached();
      channel.fromWorker(
        ApprovalRequestMsg(id: 'ap-2', call: {}, reason: 'unattended'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        channel.sentOf('approval_response'),
        isNull,
        reason: 'a bystander client must not answer approvals',
      );
      addTearDown(channel.close);
    },
  );

  test('a handler error still denies — the surface owes an answer', () async {
    final (:service, :channel) = await _attached();
    service.approvalPromptHandler = (request) async {
      throw StateError('dialog exploded');
    };
    channel.fromWorker(ApprovalRequestMsg(id: 'ap-3', call: {}, reason: 'r'));
    await Future<void>.delayed(Duration.zero);
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

  test('tools_state after attach drives the Tools section', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      const ToolsStateMsg(
        tools: [
          UiToolState(name: 'browser_active_tab', enabled: true),
          UiToolState(name: 'browser_inject_js', enabled: false),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final availability = service.toolAvailability;
    expect(
      availability.keys,
      unorderedEquals(['browser_active_tab', 'browser_inject_js']),
    );
    expect(availability['browser_active_tab']!.enabled, isTrue);
    expect(availability['browser_active_tab']!.capabilityPresent, isTrue);
    expect(availability['browser_inject_js']!.enabled, isFalse);
    addTearDown(channel.close);
  });

  test('setToolEnabled sends tools_put and updates optimistically', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      const ToolsStateMsg(
        tools: [UiToolState(name: 'browser_active_tab', enabled: true)],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await service.setToolEnabled('browser_active_tab', false);
    final put = channel.sentOf('tools_put');
    expect(put, isNotNull);
    expect((put!['tools'] as List).single, {
      'name': 'browser_active_tab',
      'enabled': false,
    });
    expect(service.toolAvailability['browser_active_tab']!.enabled, isFalse);
    addTearDown(channel.close);
  });

  test('the SW provider snapshot feeds the models screens', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      const SettingsResultMsg(
        settings: {
          'faProvider': {
            'baseUrl': 'https://api.kimi.com/coding/v1',
            'apiKey': 'k2-secret',
            'model': 'kimi-k2',
          },
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.swProvider, isNotNull);
    expect(service.swProvider!['model'], 'kimi-k2');
    expect(service.swProvider!['baseUrl'], 'https://api.kimi.com/coding/v1');

    // The Default-chat-model row renders the FaChatConnection getters —
    // they must reflect the SW snapshot, not the idle local agent.
    expect(service.modelId, 'kimi-k2');
    expect(service.activeBaseUrl, 'https://api.kimi.com/coding/v1');
    expect(service.providerKind, 'openai-completions');
    addTearDown(channel.close);
  });

  test('ready completes once attach and settings snapshot landed', () async {
    final channel = FakePortChannel();
    final transport = WorkerRelayTransport(
      portFactory: () => channel,
      channel: channel,
    );
    final service = RelayAgentService.forTest(transport);
    final done = service.ready.timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('ready never completed'),
    );
    channel.fromWorker(
      HelloAckMsg(
        protoVersion: uiProtocolVersion,
        serverCapabilities: const [],
        sessionId: 'sw-1',
      ),
    );
    channel.fromWorker(const AttachedMsg(sessionId: 'sw-1', replay: []));
    channel.fromWorker(
      const SettingsResultMsg(
        settings: {
          'faProvider': {
            'baseUrl': 'https://api.kimi.com/coding/v1',
            'apiKey': 'k',
            'model': 'kimi-k2',
          },
        },
      ),
    );
    await done;
    expect(service.swProvider!['model'], 'kimi-k2');
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
