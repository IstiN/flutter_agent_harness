// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/agent_service.dart'
    show AgentConfig, ProviderConnectionException;
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

  test('an attach broadcast with a NEW session id fires the adoption '
      'callback (live session switched from another surface)', () async {
    final (:service, :channel) = await _attached();
    final adopted = <String>[];
    service.onLiveSessionIdChanged = adopted.add;
    expect(service.liveSessionId, 'sw-1');
    channel.fromWorker(AttachedMsg(sessionId: 'sw-2', replay: const []));
    await pumpEventQueue();
    expect(service.liveSessionId, 'sw-2');
    expect(adopted, ['sw-2']);
    // Same id again — no spurious callback.
    channel.fromWorker(AttachedMsg(sessionId: 'sw-2', replay: const []));
    await pumpEventQueue();
    expect(adopted, ['sw-2']);
  });

  test(
    'hello resyncs the SW live id — a missed switch while away heals',
    () async {
      // A panel reload / SW reconnect lands on a hello carrying the SW's
      // CURRENT live session: any session_new/session_open broadcast missed
      // while detached must heal here, or hostedLiveId points at a session
      // that renders nowhere and every selection dot disappears.
      final channel = FakePortChannel();
      final transport = WorkerRelayTransport(
        portFactory: () => channel,
        channel: channel,
      );
      final service = RelayAgentService.forTest(transport);
      final adopted = <String>[];
      service.onLiveSessionIdChanged = adopted.add;
      final connected = transport.connect();
      await () async {
        while (channel.sentOf('hello') == null) {
          await Future<void>.delayed(Duration.zero);
        }
        channel.fromWorker(
          HelloAckMsg(
            protoVersion: uiProtocolVersion,
            serverCapabilities: const ['stream', 'approvals'],
            sessionId: 'sw-9',
          ),
        );
        while (channel.sentOf('attach') == null) {
          await Future<void>.delayed(Duration.zero);
        }
        channel.fromWorker(AttachedMsg(sessionId: 'sw-9', replay: const []));
      }();
      await connected;
      expect(service.liveSessionId, 'sw-9');
      expect(adopted, ['sw-9']);
    },
  );

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

  test('replay rows with dartify-style nested maps still render', () async {
    // The port transport decodes JS objects via dartify(): the OUTER map
    // is converted by the protocol decoder, but NESTED maps keep the
    // Map<Object?, Object?> type. _rebuild must not drop such rows (this
    // bug rendered "No messages yet" against a delivered replay).
    final eventA = <Object?, Object?>{
      'type': 'message_done',
      'role': 'user',
      'text': 'dartify user row',
    };
    final (:service, :channel) = await _attached(
      replay: [
        {'seq': 1, 'event': eventA},
      ],
    );
    expect(service.messages, hasLength(1));
    expect(service.messages.single.role, 'user');
    expect(service.messages.single.content, 'dartify user row');
    addTearDown(channel.close);
  });

  test('transcript replay renders user, assistant and tool rows', () async {
    // The SW synthesizes the durable backlog (see transcriptReplayOf):
    // history rows land through the same _rebuild path.
    final (:service, :channel) = await _attached(
      replay: [
        {
          'seq': 1,
          'event': {
            'type': 'message_done',
            'role': 'user',
            'text': 'open example.com',
          },
        },
        {
          'seq': 2,
          'event': {
            'type': 'message_done',
            'role': 'assistant',
            'text': 'opening it now',
          },
        },
        {
          'seq': 3,
          'event': {
            'type': 'tool_result',
            'toolName': 'browser_navigate',
            'isError': false,
            'text': '{"ok":true}',
          },
        },
      ],
    );
    expect(service.messages.map((m) => m.role).toList(), [
      'user',
      'assistant',
      'tool',
    ]);
    expect(service.messages[2].toolName, 'browser_navigate');
    expect(service.messages[2].content, '{"ok":true}');
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

  test('isStreaming rides the SW status, not the link-phase machine', () async {
    // A turn spans approval/tool waits where NO data flows: message_done
    // (a tool-call step boundary) flips the link back to attached, and
    // driving _running from the transport state killed the typing
    // indicator mid-turn (and re-enabled session actions against a busy
    // SW). The SW's status events are the turn's ground truth.
    final (:service, :channel) = await _attached();
    await service.sendText('turn with tools');
    await Future<void>.delayed(Duration.zero);
    expect(service.isStreaming, isTrue); // optimistic send
    // SW turn-start mirror.
    channel.fromWorker(
      const StreamMsg(event: {'type': 'status', 'running': true}),
    );
    await Future<void>.delayed(Duration.zero);
    // Tool-call step boundary: flips the LINK to attached…
    channel.fromWorker(
      const MessageDoneMsg(message: {'role': 'assistant', 'text': ''}),
    );
    await Future<void>.delayed(Duration.zero);
    // …but the turn is still alive (approval/tool wait ahead).
    expect(service.isStreaming, isTrue);
    expect(service.openSessionAction, isNull);
    // SW says the turn is over — only NOW the indicator clears.
    channel.fromWorker(
      const StreamMsg(event: {'type': 'status', 'running': false}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.isStreaming, isFalse);
    expect(service.openSessionAction, isNotNull);
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

  test('session names round-trip the SW settings channel '
      '(faSessionNames)', () async {
    final (:service, :channel) = await _attached();
    addTearDown(channel.close);
    // A snapshot from the SW (another surface renamed s-1) seeds the store.
    channel.fromWorker(
      SettingsResultMsg(
        settings: {
          'faSessionNames': {'s-1': 'one'},
        },
      ),
    );
    await pumpEventQueue();
    expect(service.namesStoreOverride, same(service.namesStore));
    expect(service.namesStore.titleFor('s-1'), 'one');

    // Rename s-2 → settings_put carries the full names map.
    await service.namesStore.rename('s-2', 'two');
    final put = channel.sentOf('settings_put');
    expect(put, isNotNull);
    expect((put!['settings'] as Map)['faSessionNames'], {
      's-1': 'one',
      's-2': 'two',
    });

    // The SW merges + broadcasts; clearing s-2 sends a tombstone.
    channel.fromWorker(
      SettingsResultMsg(
        settings: {
          'faSessionNames': {'s-1': 'one', 's-2': 'two'},
        },
      ),
    );
    await pumpEventQueue();
    await service.namesStore.rename('s-2'); // clear
    final put2 = channel.sentOf('settings_put');
    expect((put2!['settings'] as Map)['faSessionNames'], {
      's-1': 'one',
      's-2': '',
    });
    expect(service.namesStore.titleFor('s-2'), isNull);

    // A broadcast from ANOTHER surface updates the store live.
    channel.fromWorker(
      SettingsResultMsg(
        settings: {
          'faSessionNames': {'s-1': 'one', 's-3': 'three'},
        },
      ),
    );
    await pumpEventQueue();
    expect(service.namesStore.titleFor('s-3'), 'three');
    expect(service.namesStore.titleFor('s-2'), isNull);
  });

  test('settings snapshots forward the SW approval mode into the shell '
      '(issue #380: mode forwarded, not defaulted)', () async {
    final (:service, :channel) = await _attached();
    addTearDown(channel.close);
    // The relay shell defaults to write; the SW gate owns the real mode.
    expect(service.approval.mode, ApprovalMode.write);
    channel.fromWorker(
      const SettingsResultMsg(settings: {'faApproval': 'yolo'}),
    );
    await pumpEventQueue();
    expect(service.approval.mode, ApprovalMode.yolo);

    // A snapshot without (or with an unknown) faApproval leaves the
    // forwarded mode alone.
    channel.fromWorker(const SettingsResultMsg(settings: {}));
    await pumpEventQueue();
    expect(service.approval.mode, ApprovalMode.yolo);
    channel.fromWorker(
      const SettingsResultMsg(settings: {'faApproval': 'nonsense'}),
    );
    await pumpEventQueue();
    expect(service.approval.mode, ApprovalMode.yolo);

    // A mode change from ANOTHER surface lands live (mid-session sync).
    channel.fromWorker(
      const SettingsResultMsg(settings: {'faApproval': 'unattended'}),
    );
    await pumpEventQueue();
    expect(service.approval.mode, ApprovalMode.unattended);

    // A panel toggle still writes through; the SW echo applies the same
    // value (no put-back, no loop).
    service.setApprovalMode(ApprovalMode.write);
    final put = channel.sentOf('settings_put');
    expect((put!['settings'] as Map)['faApproval'], 'write');
    expect(service.approval.mode, ApprovalMode.write);
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
      unorderedEquals([
        'browser_active_tab',
        'browser_inject_js',
        // The host-bound office family gates even when the SW never
        // reports it (issue #327 AC5).
        'outlook',
      ]),
    );
    expect(availability['outlook']!.capabilityPresent, isFalse);
    expect(availability['outlook']!.enabled, isFalse);
    expect(
      availability['outlook']!.reason,
      'available in the Outlook add-in host only',
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
  test('reconfigure runs the mixed-row guard BEFORE settings_put '
      '(issue #327)', () async {
    final (:service, :channel) = await _attached();
    addTearDown(service.dispose);
    final registry = ProviderRegistry.inMemory();
    await registry.add(
      name: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'z-ai/glm-5.3-flash',
    );
    // The boot wiring hands the panel registry to the relay service.
    service.providerRegistry = registry;
    // An OpenRouter-format model id riding a different host's connection:
    // the #327 fingerprint - refused, no settings_put ever dispatched.
    await expectLater(
      service.reconfigure(
        AgentConfig(
          providerKind: 'openai-completions',
          modelId: 'z-ai/glm-5.3-flash',
          baseUrl: 'https://acme.example.com/code-assistant-api/v1',
          apiKey: 'k',
        ),
      ),
      throwsA(isA<ProviderConnectionException>()),
    );
    expect(channel.sentOf('settings_put'), isNull);
    expect(service.error, isNotNull);
  });

  group('attachment staging over the relay (#313)', () {
    Future<Map<String, dynamic>> _nextExtFrame(
      FakePortChannel channel,
      String op,
    ) async {
      for (var i = 0; i < 50; i++) {
        final frame = channel.sentOf('ext_request');
        if (frame != null && frame['op'] == op) return frame;
        await Future<void>.delayed(Duration.zero);
      }
      fail('no $op ext_request frame sent');
    }

    test('stageAttachment dispatches agent.stageUpload and returns '
        'the SW path', () async {
      final (:service, :channel) = await _attached();
      addTearDown(channel.close);
      final bytes = Uint8List.fromList(List.filled(200 * 1024, 0x61));
      final staged = service.stageAttachment(
        name: 'pasted-1789302656781.txt',
        bytes: bytes,
      );
      final frame = await _nextExtFrame(channel, 'agent.stageUpload');
      expect(frame['params']['name'], 'pasted-1789302656781.txt');
      expect(base64Decode(frame['params']['bytes'] as String), bytes);
      channel.fromWorker(
        ExtResultMsg(
          id: frame['id'] as String,
          ok: true,
          data: {'path': 'uploads/pasted-1789302656781.txt'},
        ),
      );
      expect(await staged, 'uploads/pasted-1789302656781.txt');
    });

    test('stageAttachment surfaces a named SW refusal', () async {
      final (:service, :channel) = await _attached();
      addTearDown(channel.close);
      final staged = service.stageAttachment(
        name: 'big.bin',
        bytes: Uint8List(1),
      );
      final frame = await _nextExtFrame(channel, 'agent.stageUpload');
      channel.fromWorker(
        ExtResultMsg(
          id: frame['id'] as String,
          ok: false,
          error: 'upload too large: 1 byte exceeds the 20 MB staging cap',
        ),
      );
      await expectLater(staged, throwsStateError);
    });

    test('stageAttachment pre-checks the cap BEFORE encoding (review '
        'minor 2)', () async {
      final (:service, :channel) = await _attached();
      addTearDown(channel.close);
      final staged = service.stageAttachment(
        name: 'pasted-huge.txt',
        bytes: Uint8List(kMaxStageUploadBytes + 1),
      );
      await expectLater(
        staged,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'upload too large: ${kMaxStageUploadBytes + 1} bytes exceeds '
                'the 20 MB staging cap',
          ),
        ),
      );
      // No frame ever left the panel: the refusal is local, no wasted
      // 4/3 base64 expansion over the wire.
      expect(channel.sentOf('ext_request'), isNull);
    });

    test('a dropped SW port fails pending staging with a clean note '
        '(AC4)', () async {
      final (:service, :channel) = await _attached();
      final staged = service.stageAttachment(
        name: 'pasted-2.txt',
        bytes: Uint8List(1),
      );
      final frame = await _nextExtFrame(channel, 'agent.stageUpload');
      expect(frame, isNotNull);
      // The SW dies before the ext_result: the port closes, the transport
      // goes Dropped, and the in-flight paste must not hang forever.
      channel.close();
      await expectLater(
        staged,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'extension service worker disconnected',
          ),
        ),
      );
    });

    test('sendAttachments verifies staged files and references their '
        'paths before the typed text', () async {
      final (:service, :channel) = await _attached();
      addTearDown(channel.close);
      final sent = service.sendAttachments(
        attachments: [
          (
            path: 'uploads/pasted-1.txt',
            bytes: Uint8List(0),
            mimeType: 'text/plain',
          ),
        ],
        text: 'summarize this',
      );
      final frame = await _nextExtFrame(channel, 'agent.missingUploads');
      expect(frame['params']['paths'], ['uploads/pasted-1.txt']);
      channel.fromWorker(
        ExtResultMsg(
          id: frame['id'] as String,
          ok: true,
          data: {'missing': <String>[]},
        ),
      );
      await sent;
      final prompt = channel.sentOf('prompt');
      expect(prompt, isNotNull);
      expect(
        prompt!['text'],
        '[attached file: uploads/pasted-1.txt — read it with your tools]\n'
        'summarize this',
      );
    });

    test('sendAttachments names lost staged files — never a silently '
        'empty reference (SW restart with a pending chip)', () async {
      final (:service, :channel) = await _attached();
      addTearDown(channel.close);
      final sent = service.sendAttachments(
        attachments: [
          (
            path: 'uploads/pasted-1.txt',
            bytes: Uint8List(0),
            mimeType: 'text/plain',
          ),
        ],
        text: 'summarize this',
      );
      final frame = await _nextExtFrame(channel, 'agent.missingUploads');
      channel.fromWorker(
        ExtResultMsg(
          id: frame['id'] as String,
          ok: true,
          data: {
            'missing': ['uploads/pasted-1.txt'],
          },
        ),
      );
      await expectLater(
        sent,
        throwsA(
          predicate(
            (StateError e) => e.message.contains('re-attach'),
            'StateError naming re-attach',
          ),
        ),
      );
      expect(channel.sentOf('prompt'), isNull);
    });

    test('discardStagedAttachment best-effort deletes only inside '
        'uploads/', () async {
      final (:service, :channel) = await _attached();
      addTearDown(channel.close);
      await service.discardStagedAttachment('session-1.jsonl');
      expect(channel.sentOf('ext_request'), isNull);
      final removed = service.discardStagedAttachment('uploads/a.txt');
      final frame = await _nextExtFrame(channel, 'agent.discardUpload');
      expect(frame['params']['path'], 'uploads/a.txt');
      channel.fromWorker(
        ExtResultMsg(id: frame['id'] as String, ok: true, data: {}),
      );
      await removed;
    });

    test('E1: staging without the SW agent is a named refusal, not a '
        'crash', () async {
      final channel = FakePortChannel();
      addTearDown(channel.close);
      final transport = WorkerRelayTransport(
        portFactory: () => channel,
        channel: channel,
      );
      final service = RelayAgentService.forTest(transport);
      // No hello/attach handshake: the port server is up (scaffold
      // checkout) but the agent host never booted — the op refuses with
      // the same named string the SW agent-guarded ops give.
      await expectLater(
        service.stageAttachment(
          name: 'pasted-1.txt',
          bytes: Uint8List.fromList('x'.codeUnits),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'agent not built (missing sw/agent.js)',
          ),
        ),
      );
      expect(channel.sentOf('ext_request'), isNull);
    });
  });
  _mailTests();
  _reviewFixTests();
}

/// The fa_ui placeholder, re-exported for the assertion above.
const faEmptyResponsePlaceholder = emptyResponsePlaceholder;

// -- Issue #320: inbound hub/DAP/bridge mail is visible in the v2 chat ------

void _mailTests() {
  test('IT-mailvisible: inbound mail renders a user bubble at arrival '
      'before the assistant reply (#320 S1)', () async {
    final (:service, :channel) = await _attached();
    // Idle-arrival mail: the SW starts the turn and announces the
    // attributed user message before any assistant delta. No composer
    // echo exists for host-initiated turns — the row must render live.
    channel.fromWorker(
      const MessageDoneMsg(
        message: {'role': 'user', 'text': '[from peer-1] hallo from hub'},
      ),
    );
    channel.fromWorker(
      const StreamMsg(event: {'type': 'delta', 'text': 'fake: working'}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .toList(),
      ['[from peer-1] hallo from hub'],
    );
    addTearDown(channel.close);
  });

  test('the composer echo stays singular — the live user message_done '
      'matching the echoed text is skipped (#320 keeps AC)', () async {
    final (:service, :channel) = await _attached();
    await service.sendText('привет');
    channel.fromWorker(
      const MessageDoneMsg(message: {'role': 'user', 'text': 'привет'}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .toList(),
      ['привет'],
    );
    addTearDown(channel.close);
  });

  test('a per-turn [context] prefix does not break the echo match '
      '(#320 keeps AC)', () async {
    final (:service, :channel) = await _attached();
    await service.sendText('tab question');
    channel.fromWorker(
      const MessageDoneMsg(
        message: {
          'role': 'user',
          'text':
              '[context] active tab: Example — https://example.com\n'
              'tab question',
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .toList(),
      ['tab question'],
    );
    addTearDown(channel.close);
  });

  test('IT-pending: mid-run mail shows a queued indicator until the '
      'boundary delivery renders the bubble once (#320 S3/AC3)', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      const StreamMsg(
        event: {
          'type': 'status',
          'running': true,
          'mail': {
            'pending': 2,
            'senders': ['peer-1', 'peer-2'],
          },
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages.map((m) => m.content),
      contains(
        '2 queued messages from peer-1, peer-2 — '
        'will land at the next step boundary',
      ),
    );
    // The boundary: the drain refresh clears the indicator, then the
    // delivered mail renders exactly once.
    channel.fromWorker(
      const StreamMsg(event: {'type': 'status', 'running': true}),
    );
    channel.fromWorker(
      const MessageDoneMsg(
        message: {'role': 'user', 'text': '[from peer-1] mid-run hello'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.messages.where((m) => m.role == 'system'), isEmpty);
    expect(
      service.messages.where(
        (m) => m.role == 'user' && m.content == '[from peer-1] mid-run hello',
      ),
      hasLength(1),
    );
    addTearDown(channel.close);
  });

  test('IT-routing: a binding session switch renders the routing notice '
      '(#320 S4/AC4)', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      const StreamMsg(
        event: {'type': 'mail_routed', 'from': 'peer-1', 'sessionId': 'ded-7'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages.map((m) => m.content),
      contains('mail from peer-1 routed to session ded-7'),
    );
    addTearDown(channel.close);
  });

  test('IT-transcript: a mail user row in transcriptReplay renders after '
      'attach, exactly once (#320 S2/AC2)', () async {
    final (:service, :channel) = await _attached(
      replay: [
        {
          'type': 'message_done',
          'role': 'user',
          'text': '[from peer-1] hallo from history',
        },
      ],
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .toList(),
      ['[from peer-1] hallo from history'],
    );
    addTearDown(channel.close);
  });

  test('IT-transcript: a replayed composer row keeps its per-turn [context] '
      'header stripped, mail rows verbatim (#320 S2)', () async {
    final (:service, :channel) = await _attached(
      replay: [
        {
          'type': 'message_done',
          'role': 'user',
          'text':
              '[context] active tab: Example — https://example.com\n'
              'my composer text',
        },
        {
          'type': 'message_done',
          'role': 'user',
          'text': '[from peer-2] verbatim mail',
        },
      ],
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .toList(),
      ['my composer text', '[from peer-2] verbatim mail'],
    );
    addTearDown(channel.close);
  });
}

// -- PR #324 rework: ledger reset on re-attach, CodeMie auto-resend,
// -- FIFO composer echoes, mail_routed paint. ------------------------------

void _reviewFixTests() {
  test(
    'IT-reattach: a re-attach resets the trajectory ledger — it never '
    'stacks the new session replay on top of the old one (#320 MAJOR 1)',
    () async {
      final (:service, :channel) = await _attached(
        replay: [
          {'type': 'message_done', 'role': 'user', 'text': 's1 question'},
          {'type': 'message_done', 'role': 'assistant', 'text': 's1 answer'},
        ],
      );
      await Future<void>.delayed(Duration.zero);
      final before = await service.trajectory.first;
      expect(before.records.length, 2);
      // A DIFFERENT session's ring: the ledger must reset, not append.
      channel.fromWorker(
        const AttachedMsg(
          sessionId: 'sw-2',
          replay: [
            {'type': 'message_done', 'role': 'user', 'text': 's2 question'},
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final after = await service.trajectory.first;
      expect(after.records.length, 1);
      addTearDown(channel.close);
    },
  );

  test('IT-codemie: the auth-expired auto flow resends the failed prompt '
      'once the sign-in poll succeeds (#320 MAJOR 2)', () async {
    RelayAgentService.codemieSignInPollOverride =
        ({required probe, required openLoginPage}) async => ['glm-5.3-flash'];
    addTearDown(() => RelayAgentService.codemieSignInPollOverride = null);
    final (:service, :channel) = await _attached();
    // The SW's persisted provider: an absolute CodeMie base URL so the
    // auth-expired path arms the reactive flow.
    channel.fromWorker(
      const SettingsResultMsg(
        settings: {
          'faProvider': {
            'model': 'glm-5.3-flash',
            'baseUrl': 'https://codemie.example.com/api',
            'apiKey': 'k',
          },
        },
      ),
    );
    await service.sendText('resend me');
    // Real time between the original send and the failure: the resend
    // mints a fresh prompt id (same-microsecond ids are deduped by the
    // transport as double-taps — by design).
    await Future<void>.delayed(const Duration(milliseconds: 2));
    // The dead turn ends the way the SW reports it: the status mirror
    // clears `running`, then the errored assistant row lands.
    channel.fromWorker(
      const StreamMsg(event: {'type': 'status', 'running': false}),
    );
    channel.fromWorker(
      const StreamMsg(
        event: {
          'type': 'message_done',
          'role': 'assistant',
          'text': '',
          'error': '[[auth-expired:codemie]] session expired',
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final prompts = channel.sent.where((j) => j['kind'] == 'prompt').toList();
    expect(prompts.length, 2);
    expect(prompts.last['text'], 'resend me');
    expect(service.messages.last.content, contains('resending your message'));
    addTearDown(channel.close);
  });

  test('IT-steerfifo: several steers inside one boundary window each '
      'render exactly once — no duplicate bubbles (#320 MAJOR 3)', () async {
    final (:service, :channel) = await _attached();
    channel.fromWorker(
      const StreamMsg(event: {'type': 'status', 'running': true}),
    );
    await service.sendText('first');
    await service.sendText('second');
    // The SW echoes BOTH steered rows at the boundary, in order.
    channel.fromWorker(
      const MessageDoneMsg(message: {'role': 'user', 'text': 'first'}),
    );
    channel.fromWorker(
      const MessageDoneMsg(message: {'role': 'user', 'text': 'second'}),
    );
    // Host-initiated mail at the same boundary still renders.
    channel.fromWorker(
      const MessageDoneMsg(
        message: {'role': 'user', 'text': '[from peer-3] mail'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      service.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .toList(),
      ['first', 'second', '[from peer-3] mail'],
    );
    addTearDown(channel.close);
  });

  test('IT-routedpaint: the mail_routed notice paints at arrival, not at '
      'the routed turn\'s first delta (#320 MINOR)', () async {
    final (:service, :channel) = await _attached();
    var notifications = 0;
    service.addListener(() => notifications++);
    channel.fromWorker(
      const StreamMsg(
        event: {
          'type': 'mail_routed',
          'from': 'peer-9',
          'sessionId': 'sw-route',
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(notifications, greaterThan(0));
    expect(service.messages.last.content, contains('sw-route'));
    addTearDown(channel.close);
  });
}
