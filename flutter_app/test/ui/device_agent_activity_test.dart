// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/chats/chat_list_entry.dart' show ChatPresence;
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import '../network/device_connector_service_test.dart' as fixture;
import '../network/fakes.dart';
import 'devices_page_test.dart'
    show FakeDevicesService, chatListOf, devicesPage, localEntry;

final class _ActivitySource extends ChangeNotifier
    implements DeviceChatSessionSource, DeviceChatSessionActivitySource {
  List<DeviceChatSessionActivity> activity = const [
    (id: 'session-live', busy: false),
  ];

  @override
  Listenable get changes => this;

  @override
  Future<List<DeviceChatSession>> load() async => const [
    (id: 'session-live', live: true),
  ];

  @override
  Future<List<DeviceChatSessionActivity>> loadActivity() async =>
      List.of(activity);

  void setBusy(bool busy) {
    activity = [(id: 'session-live', busy: busy)];
    notifyListeners();
  }
}

Future<void> _until(bool Function() probe) async {
  for (var i = 0; i < 300; i++) {
    if (probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('activity roster condition did not settle');
}

Widget _wrap(Widget child) => MaterialApp(
  theme: buildFahTheme(),
  home: Scaffold(body: SizedBox(width: 420, height: 700, child: child)),
);

void main() {
  test(
    'real session run state maps idle → busy → idle and decodes additively',
    () async {
      expect(AgentRunState.tryParse('busy'), AgentRunState.busy);
      expect(AgentRunState.tryParse('future-state'), isNull);
      final decoded = PresenceFrame.fromEnvelope(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.presence,
          msgId: 'presence-tolerant',
          ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
          payload: {
            'machine': 'online',
            'agents': [
              {'address': 'fa@dev-1', 'state': 'busy'},
              {'address': 'old@dev-1', 'state': 'future-state'},
            ],
          },
        ),
      );
      expect(decoded?.agents, {'fa@dev-1': AgentRunState.busy});

      final source = _ActivitySource();
      final http = FakeHttpClient()
        ..respond(200, body: '{"ticket":"tk-agent-activity"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"patched":"dev-1"}')
        ..respond(200, body: '{"patched":"dev-1"}');
      final (service, _, _, _, _) = await fixture.buildService(
        httpClient: http,
        tokenStore: fixture.enrolledTokens(),
        chatSessionSource: source,
        rosterDebounce: const Duration(milliseconds: 20),
      );
      addTearDown(service.dispose);
      await service.start();
      await fixture.pumpUntilOnline(service);
      await _until(() => fixture.rosterPatches(http).isNotEmpty);
      expect(
        (fixture.rosterPatches(http).single['agents']! as List).single,
        fixture.agentPatch('live', true),
      );

      source.setBusy(true);
      await _until(() => fixture.rosterPatches(http).length >= 2);
      expect(
        (fixture.rosterPatches(http)[1]['agents']! as List).single,
        fixture.agentPatch('busy', true),
      );
      source.setBusy(false);
      await _until(() => fixture.rosterPatches(http).length >= 3);
      expect(
        (fixture.rosterPatches(http)[2]['agents']! as List).single,
        fixture.agentPatch('live', true),
      );
    },
  );

  test(
    'publisher adapter reads each real AgentService run independently',
    () async {
      final env = MemoryExecutionEnv();
      final release = Completer<void>();
      Agent agent(StreamFunction streamFunction) => Agent(
        model: Model(
          id: 'activity-model',
          api: 'test-api',
          provider: 'test',
          baseUrl: 'https://example.com',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        systemPrompt: 'activity test',
        streamFunction: streamFunction,
        toolRegistry: ToolRegistry(const []),
      );
      final idle = AgentService(
        agent: agent((model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.end();
          return stream;
        }),
        env: env,
        sessionsRoot: '/activity-sessions',
      );
      final busy = AgentService(
        agent: agent((model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          unawaited(
            release.future.then((_) {
              stream.push(
                DoneEvent(
                  reason: StopReason.stop,
                  message: AssistantMessage(
                    content: const [TextContent(text: 'done')],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    usage: Usage.zero,
                    stopReason: StopReason.stop,
                    timestamp: DateTime.utc(2026, 11, 12),
                  ),
                ),
              );
              stream.end();
            }),
          );
          return stream;
        }),
        env: env,
        sessionsRoot: '/activity-sessions',
      );
      await idle.initialize();
      await busy.initialize();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/activity-sessions',
        includeSharedSessionRoots: false,
      );
      addTearDown(manager.dispose);
      manager.addSession('idle-session', idle);
      manager.addSession('busy-session', busy);
      final source = createDeviceChatSessionSource(manager);
      var changeCount = 0;
      void onChanged() => changeCount++;
      source.changes.addListener(onChanged);
      addTearDown(() => source.changes.removeListener(onChanged));
      expect(await (source as DeviceChatSessionActivitySource).loadActivity(), [
        (id: 'idle-session', busy: false),
        (id: 'busy-session', busy: false),
      ]);

      unawaited(busy.sendText('hold this turn'));
      await _until(() => busy.isStreaming && changeCount > 0);
      final running = await (source as DeviceChatSessionActivitySource)
          .loadActivity();
      expect(
        running.singleWhere((row) => row.id == 'idle-session').busy,
        isFalse,
      );
      expect(
        running.singleWhere((row) => row.id == 'busy-session').busy,
        isTrue,
      );

      final runningChangeCount = changeCount;
      release.complete();
      await busy.waitForIdle();
      await _until(() => changeCount > runningChangeCount);
      final settled = await (source as DeviceChatSessionActivitySource)
          .loadActivity();
      expect(settled.every((row) => !row.busy), isTrue);
    },
  );

  testWidgets('own and remote Devices agent rows render busy vs idle', (
    tester,
  ) async {
    final service = FakeDevicesService(
      initialPhase: DeviceConnectorPhase.online,
      deviceId: 'dev-own',
      personalNetworkId: 'net-personal',
    );
    service.seededRoster.add(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'remote-busy',
        ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
        network: 'net-personal',
        payload: {
          'devices': [
            {
              'deviceId': 'dev-remote',
              'name': 'Duo',
              'agents': [
                {
                  'name': 'fa',
                  'state': 'busy',
                  'exposed': true,
                  'dmPub': 'cHVi',
                },
              ],
            },
          ],
        },
      ),
    );
    final sessions = chatListOf([
      localEntry('own-busy', presence: ChatPresence.busy),
    ]);
    await tester.pumpWidget(_wrap(devicesPage(service, sessions: sessions)));
    service.emitPresence(
      PresenceFrame(
        msgId: 'own-busy',
        ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
        machine: MachinePresence.online,
        agents: const {'fa@dev-own': AgentRunState.busy},
      ),
    );
    await tester.pump();
    final colors = FahColors.of(
      tester.element(find.byKey(const ValueKey('devicesPage'))),
    );
    DeviceSessionCard agentRow() => tester.widget<DeviceSessionCard>(
      // Agent rows are keyed by the CANONICAL mailbox name (REST `fa` and
      // presence `fa@dev-own` aliases dedup into one row).
      find.byKey(const ValueKey('agentRow:fa')),
    );
    expect(agentRow().stateLabel, 'Busy');
    expect(agentRow().dotColor, colors.pending);
    final localCard = tester.widget<DeviceSessionCard>(
      find.byKey(const ValueKey('sessionRow:own-busy')),
    );
    expect(localCard.dotColor, colors.pending);

    service.emitPresence(
      PresenceFrame(
        msgId: 'own-idle',
        ts: rfc3339Timestamp(DateTime.utc(2026, 11, 12)),
        machine: MachinePresence.online,
        agents: const {'fa@dev-own': AgentRunState.live},
      ),
    );
    await tester.pump();
    expect(agentRow().stateLabel, 'Online');
    expect(agentRow().dotColor, colors.teal);

    await tester.tap(find.byKey(const ValueKey('deviceRow:dev-remote')));
    await tester.pump();
    // Own and remote devices both expose the canonical `fa` row; pick the
    // remote (still busy) card after expanding its device.
    final remoteAgent = tester
        .widgetList<DeviceSessionCard>(find.byKey(const ValueKey('agentRow:fa')))
        .singleWhere((card) => card.stateLabel == 'Busy');
    expect(remoteAgent.dotColor, colors.pending);
  });
}
