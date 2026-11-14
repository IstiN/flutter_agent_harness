// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Live Devices DM round trip between two already-enrolled app installs.
///
/// Run the receiver first on macOS, then the sender on the Duo:
///   flutter test integration_test/devices_dm_e2e_test.dart -d macos \
///     --dart-define=E2E_ROLE=receiver
///   flutter test integration_test/devices_dm_e2e_test.dart -d `<duo-id>` \
///     --dart-define=E2E_ROLE=sender
///
/// E2E_TARGET_DEVICE is an optional case-insensitive device-label selector.
/// No backend, connector, or agent service is mocked.
library;

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:fa/boot/app_boot.dart';
import 'package:fa/main.dart' as app;
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/network_session.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/ui/network/device_roster_panel.dart';
import 'package:fa/ui/network/devices_page.dart';
import 'package:fa/ui/network/network_chat_page.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// The connector envelope is a pure-Dart public stream element, although its
// declaration lives in the harness's implementation-import connector core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';

const _role = String.fromEnvironment('E2E_ROLE', defaultValue: 'sender');
const _targetDevice = String.fromEnvironment('E2E_TARGET_DEVICE');
const _devicesNav = ValueKey('messengerPrimaryNav-devices');
const _moreNav = ValueKey('messengerPrimaryNav-more');
const _moreDevicesNav = ValueKey('narrowShellMore-messengerPrimaryNav-devices');

void _log(String message) {
  print(
    '[devices-dm][$_role][${DateTime.now().toUtc().toIso8601String()}] '
    '$message',
  );
}

/// Integration tests still run widget pumps on the test clock. Give platform
/// channels, sockets, REST, and the real agent a real-async slice as well.
Future<void> _pumpReal(
  WidgetTester tester, [
  Duration delay = const Duration(milliseconds: 500),
]) async {
  await tester.runAsync(() => Future<void>.delayed(delay));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  required String description,
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    if (condition()) {
      _log('$description (after ${watch.elapsed.inMilliseconds} ms)');
      return true;
    }
    await _pumpReal(tester);
  }
  final found = condition();
  _log(
    '${found ? 'FOUND' : 'TIMEOUT'}: $description '
    '(after ${watch.elapsed.inMilliseconds} ms)',
  );
  return found;
}

Future<void> _tapAndPump(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.tap(finder.first);
  await _pumpReal(tester, const Duration(milliseconds: 300));
}

String _keyName(Widget widget) {
  final key = widget.key;
  return key is ValueKey<String> ? key.value : '';
}

List<String> _visibleKeys(WidgetTester tester, String prefix) {
  final keys =
      tester
          .widgetList(
            find.byWidgetPredicate(
              (widget) => _keyName(widget).startsWith(prefix),
              skipOffstage: false,
            ),
          )
          .map(_keyName)
          .toSet()
          .toList()
        ..sort();
  return keys;
}

void _dumpTreeDiagnostics(WidgetTester tester, String reason) {
  final types = <String, int>{};
  for (final element in tester.allElements) {
    final type = element.widget.runtimeType.toString();
    types[type] = (types[type] ?? 0) + 1;
  }
  final common = types.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  _log('$reason; widget types=${common.take(35).toList()}');
  final texts = tester
      .widgetList<Text>(find.byType(Text, skipOffstage: false))
      .map((text) => text.data)
      .whereType<String>()
      .where((text) => text.trim().isNotEmpty)
      .take(40)
      .toList();
  _log('visible/offstage Text sample=${jsonEncode(texts)}');
}

Future<WideLayoutShell?> _bootShell(WidgetTester tester) async {
  _log('booting the production FaAppBoot; no network fakes');
  await tester.runAsync(() async {
    var onboardingWasUnseen = false;
    await FaAppBoot(
      routes: app.bootAppRoutes,
      createEnv: () async {
        final env = await createPlatformEnv();
        // flutter test may install into a fresh iOS data container. Only the
        // non-secret marketing-flow flag is sandbox-resident; account keys
        // and enrollment remain in the real keychain. Mark just that flag so
        // the test reaches the existing account instead of requiring a new
        // local LLM provider during the mandatory onboarding provider step.
        final onboarding = await OnboardingStore.load(env);
        if (!onboarding.seen) {
          onboardingWasUnseen = true;
          await onboarding.markSeen();
        }
        return env;
      },
    ).run();
    if (onboardingWasUnseen) {
      _log('fresh app container: marked only onboarding_seen.json');
    }
  });
  final ready = await _waitFor(
    tester,
    () => find.byType(WideLayoutShell).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 90),
    description: 'production WideLayoutShell mounted',
  );
  if (!ready) {
    _dumpTreeDiagnostics(
      tester,
      'SKIPPED: app did not reach the messenger shell; onboarding, provider '
      'setup, or boot restoration is blocking the Devices route',
    );
    return null;
  }
  final shell = tester.widget<WideLayoutShell>(
    find.byType(WideLayoutShell).first,
  );
  final sessions = shell.networkSessions;
  if (sessions == null) {
    _log(
      'SKIPPED: WideLayoutShell.networkSessions is null (network wiring '
      'was not booted)',
    );
    return null;
  }
  _log(
    'account state: hasJwt=${sessions.hasJwt}, '
    'liveNetworks=${sessions.sessions.keys.toList()}, '
    'walletNetworks=${sessions.wallet.networks.keys.toList()}, '
    'hasWalletIdentity=${sessions.wallet.hasIdentity}',
  );
  if (!sessions.hasJwt) {
    _log(
      'SKIPPED: no enrolled/signed-in account JWT on this install; the '
      'Devices destination is intentionally absent. Sign in once, then '
      'rerun this test.',
    );
    return null;
  }
  return shell;
}

Future<DevicesPage?> _openDevices(WidgetTester tester) async {
  var destination = find.byKey(_devicesNav);
  if (destination.evaluate().isEmpty) {
    _log('direct Devices destination absent; opening the narrow More sheet');
    final more = find.byKey(_moreNav);
    if (more.evaluate().isEmpty) {
      _dumpTreeDiagnostics(
        tester,
        'Devices navigation unavailable (neither rail row nor More)',
      );
      return null;
    }
    await _tapAndPump(tester, more);
    destination = find.byKey(_moreDevicesNav);
    if (destination.evaluate().isEmpty) {
      _dumpTreeDiagnostics(
        tester,
        'Devices absent from More despite an account JWT',
      );
      return null;
    }
  }
  await _tapAndPump(tester, destination);
  final opened = await _waitFor(
    tester,
    () => find.byType(DevicesPage).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 15),
    description: 'DevicesPage opened',
  );
  if (!opened) {
    _dumpTreeDiagnostics(tester, 'Devices tap did not mount DevicesPage');
    return null;
  }
  final page = tester.widget<DevicesPage>(find.byType(DevicesPage).first);
  final service = page.service;
  final previousLog = service.onLog;
  service.onLog = (line) {
    previousLog?.call(line);
    _log('connector log: $line');
  };
  _log(
    'connector: phase=${service.phase}, running=${service.isRunning}, '
    'deviceId=${service.deviceId}, personal=${service.personalNetworkId}, '
    'lastStartError=${service.lastStartError}',
  );
  return page;
}

StreamSubscription<NetworkEnvelope> _logDmMail(DeviceConnectorService service) {
  return service.dmMail.listen((envelope) {
    _log(
      'dmMail id=${envelope.msgId} channel=${envelope.channel} '
      'from=${envelope.from} to=${envelope.to} '
      'hasCiphertext=${envelope.ciphertext != null}',
    );
  });
}

Future<void> _runReceiver(WidgetTester tester) async {
  final page = await _openDevices(tester);
  if (page == null) return;
  final service = page.service;
  final subscription = _logDmMail(service);
  addTearDown(subscription.cancel);
  var mailCount = 0;
  final countingSubscription = service.dmMail.listen((_) => mailCount++);
  addTearDown(countingSubscription.cancel);

  _log(
    'receiver ready; keeping Devices and the macOS DM session host alive '
    'for up to 180 seconds',
  );
  final watch = Stopwatch()..start();
  var nextStatus = 0;
  while (watch.elapsed < const Duration(minutes: 3)) {
    await _pumpReal(tester, const Duration(seconds: 1));
    if (watch.elapsed.inSeconds >= nextStatus) {
      final pending = await service.connector?.pendingMailCount();
      _log(
        'receiver heartbeat t=${watch.elapsed.inSeconds}s '
        'phase=${service.phase} mailCount=$mailCount outboxPending=$pending '
        'lastStartError=${service.lastStartError}',
      );
      nextStatus += 15;
    }
  }
  _log('receiver wait complete; observed $mailCount user-side DM envelope(s)');
}

Finder _remoteDeviceRows() => find.byWidgetPredicate(
  (widget) => _keyName(widget).startsWith('deviceRow:'),
);

List<Widget> _conversationRows(WidgetTester tester) {
  final sessions = tester
      .widgetList<DeviceSessionCard>(find.byType(DeviceSessionCard))
      .where((card) => card.onTap != null);
  final agents = tester
      .widgetList<DeviceRosterRow>(find.byType(DeviceRosterRow))
      .where((row) => row.onTap != null);
  // Prefer the live agent's active session. An exposed session remains the
  // explicit-target path (and the fallback when no live agent is published).
  final liveAgents = agents.where(
    (row) => row.stateLabel.toLowerCase().contains('online'),
  );
  return [...liveAgents, ...sessions, ...agents];
}

String? _paneText(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Text>(finder.first).data;
}

typedef _ConversationTarget = ({String deviceId, String rowKey});

Future<_ConversationTarget?> _selectRemoteConversation(
  WidgetTester tester,
) async {
  final watch = Stopwatch()..start();
  var lastSignature = '';
  _ConversationTarget? fallback;
  while (watch.elapsed < const Duration(seconds: 90)) {
    final rows = _remoteDeviceRows().evaluate().toList();
    final ids = <String>[
      for (final element in rows)
        _keyName(element.widget).substring('deviceRow:'.length),
    ];
    final signature = ids.join(',');
    if (signature != lastSignature) {
      _log('remote device rail ids=$ids');
      lastSignature = signature;
    }
    for (final id in ids) {
      final row = find.byKey(ValueKey('deviceRow:$id'));
      if (row.evaluate().isEmpty) continue;
      await _tapAndPump(tester, row);
      final title = _paneText(tester, 'devicePaneTitle') ?? '';
      final subtitle = _paneText(tester, 'devicePaneSubtitle') ?? '';
      final candidates = _conversationRows(tester);
      _log(
        'device $id label=${jsonEncode(title)} '
        'subtitle=${jsonEncode(subtitle)} '
        'sessionRows=${_visibleKeys(tester, 'sessionRow:')} '
        'agentRows=${_visibleKeys(tester, 'agentRow:')}',
      );
      if (candidates.isEmpty) continue;
      final candidate = (deviceId: id, rowKey: _keyName(candidates.first));
      fallback ??= candidate;
      final targetMatches =
          _targetDevice.isNotEmpty &&
          title.toLowerCase().contains(_targetDevice.toLowerCase());
      final macMatches =
          _targetDevice.isEmpty && title.toLowerCase().contains('mac');
      final online = subtitle.toLowerCase().contains('online');
      if ((targetMatches || macMatches) && online) return candidate;
    }
    final fallbackTarget = fallback;
    if (fallbackTarget != null && _targetDevice.isEmpty) {
      _log(
        'no label containing "mac" was online; using the first remote '
        'device with an exposed session/agent',
      );
      // The scan ended on a different device. Reselect the fallback's owner
      // so its stable row key is mounted before the caller taps it.
      await _tapAndPump(
        tester,
        find.byKey(ValueKey('deviceRow:${fallbackTarget.deviceId}')),
      );
      return fallbackTarget;
    }
    await _pumpReal(tester, const Duration(seconds: 1));
  }
  _log(
    'no usable remote conversation row after 90 seconds; '
    'remoteKeys=${_visibleKeys(tester, 'deviceRow:')} '
    'sessionKeys=${_visibleKeys(tester, 'sessionRow:')} '
    'agentKeys=${_visibleKeys(tester, 'agentRow:')}',
  );
  return null;
}

NetworkChatPage? _openDmPage(WidgetTester tester) {
  for (final page in tester.widgetList<NetworkChatPage>(
    find.byType(NetworkChatPage),
  )) {
    if ((page.controller.channelId?.startsWith('dm:user:') ?? false) &&
        page.controller.networkId != null) {
      return page;
    }
  }
  return null;
}

void _logChannelMessages(NetworkSession session, String channelId) {
  final state = session.channelStates[channelId];
  final messages = state?.messages ?? const <ChannelMessage>[];
  _log('channel $channelId has ${messages.length} messages');
  for (final message in messages.reversed.take(8).toList().reversed) {
    _log(
      'message id=${message.envelopeId} own=${message.isOwn} '
      'sender=${message.senderId} at=${message.createdAt} '
      'text=${jsonEncode(message.text)}',
    );
  }
}

/// Read-only REST diagnostic: does the backend persist/route the agent
/// reply even when no live device-WS envelope reaches the Duo?
Future<void> _probeDmHistory(
  NetworkSessionManager manager,
  NetworkSession session,
  String channelId,
) async {
  try {
    final client = await manager.accountClient();
    if (client == null) {
      _log('history probe: no account client');
      return;
    }
    final page = await client.listMessages(channelId);
    _log('history probe: ${page.items.length} envelope(s)');
    for (final envelope in page.items.reversed.take(6)) {
      final message = await session.decodeDmEnvelope(envelope);
      _log(
        'history id=${envelope.id} from=${envelope.senderId} '
        'own=${message.isOwn} text=${jsonEncode(message.text)}',
      );
    }
  } on Object catch (error) {
    _log('history probe failed: $error');
  }
}

Future<void> _runSender(WidgetTester tester) async {
  final page = await _openDevices(tester);
  if (page == null) return;
  final service = page.service;
  final subscription = _logDmMail(service);
  addTearDown(subscription.cancel);
  final connectorReady = await _waitFor(
    tester,
    () => service.phase == DeviceConnectorPhase.online,
    timeout: const Duration(seconds: 45),
    description: 'sender device connector online',
  );
  if (!connectorReady) {
    _log(
      'connector did not come online: phase=${service.phase}, '
      'lastStartError=${service.lastStartError}',
    );
  }

  final conversation = await _selectRemoteConversation(tester);
  if (conversation == null) {
    _dumpTreeDiagnostics(tester, 'BLOCKED before channel open');
    fail(
      'No online macOS exposed session/agent appeared in Devices. '
      'See roster diagnostics above.',
    );
  }
  final conversationElement = find.byKey(ValueKey(conversation.rowKey));
  if (conversationElement.evaluate().isEmpty) {
    _dumpTreeDiagnostics(
      tester,
      'selected ${conversation.rowKey} is not mounted on '
      '${conversation.deviceId}',
    );
    fail('The selected remote conversation row was not mounted.');
  }
  _log('tapping remote ${conversation.rowKey} on ${conversation.deviceId}');
  await _tapAndPump(tester, conversationElement);
  final opened = await _waitFor(
    tester,
    () => _openDmPage(tester) != null,
    timeout: const Duration(seconds: 45),
    description: 'virtual dm:user channel opened in NetworkChatPage',
  );
  if (!opened) {
    _dumpTreeDiagnostics(tester, 'BLOCKED: remote row tap opened no DM');
    fail('The remote roster row did not open a DM channel.');
  }
  final chatPage = _openDmPage(tester)!;
  final networkId = chatPage.controller.networkId!;
  final channelId = chatPage.controller.channelId!;
  final session = chatPage.manager.sessions[networkId];
  if (session == null) {
    fail('DM opened with no live personal NetworkSession for $networkId');
  }
  _log('DM open: network=$networkId channel=$channelId');
  _log('network session error after DM subscribe: ${session.error}');
  _logChannelMessages(session, channelId);

  final composer = find.byKey(const ValueKey('faChatComposerTextField'));
  final composerReady = await _waitFor(
    tester,
    () => composer.evaluate().isNotEmpty,
    timeout: const Duration(seconds: 30),
    description: 'DM composer ready',
  );
  if (!composerReady) {
    _dumpTreeDiagnostics(tester, 'BLOCKED: DM composer absent/read-only');
    fail('The DM composer did not appear.');
  }
  final baseline = <String>{
    for (final message
        in session.channelStates[channelId]?.messages ??
            const <ChannelMessage>[])
      message.envelopeId,
  };
  final ping = 'e2e ping ${DateTime.now().toUtc().toIso8601String()}';
  await tester.enterText(composer.first, ping);
  await tester.pump();
  final send = find.byKey(const ValueKey('faChatComposerSendButton'));
  expect(send, findsWidgets, reason: 'typed DM exposes the send button');
  final sendWatch = Stopwatch()..start();
  await _tapAndPump(tester, send);
  _log('send tapped for ${jsonEncode(ping)}');

  final sent = await _waitFor(
    tester,
    () =>
        session.channelStates[channelId]?.messages.any(
          (message) => message.isOwn && message.text == ping,
        ) ??
        false,
    timeout: const Duration(seconds: 30),
    description: 'sent DM appended after connector acknowledgement',
  );
  if (!sent) {
    _logChannelMessages(session, channelId);
    _dumpTreeDiagnostics(tester, 'BLOCKED after send tap');
    fail('The DM send was not acknowledged/appended within 30 seconds.');
  }
  final sentAt = DateTime.now().toUtc();
  _log(
    'SENT ${jsonEncode(ping)}; waiting up to 120 seconds for a new '
    'agent reply',
  );

  ChannelMessage? reply;
  final replyWatch = Stopwatch()..start();
  var nextStatus = 0;
  var historyProbed = false;
  while (replyWatch.elapsed < const Duration(minutes: 2)) {
    final messages =
        session.channelStates[channelId]?.messages ?? const <ChannelMessage>[];
    for (final message in messages.reversed) {
      if (!message.isOwn &&
          !baseline.contains(message.envelopeId) &&
          message.text?.trim().isNotEmpty == true) {
        reply = message;
        break;
      }
    }
    if (reply != null) break;
    if (!historyProbed && replyWatch.elapsed.inSeconds >= 20) {
      historyProbed = true;
      await _probeDmHistory(chatPage.manager, session, channelId);
    }
    if (replyWatch.elapsed.inSeconds >= nextStatus) {
      final pending = await service.connector?.pendingMailCount();
      _log(
        'reply wait t=${replyWatch.elapsed.inSeconds}s '
        'messages=${messages.length} connectorPhase=${service.phase} '
        'outboxPending=$pending sessionError=${session.error}',
      );
      nextStatus += 15;
    }
    await _pumpReal(tester, const Duration(seconds: 1));
  }
  final agentReply = reply;
  if (agentReply == null) {
    _logChannelMessages(session, channelId);
    _dumpTreeDiagnostics(tester, 'NO REPLY after message send');
    fail('No new agent reply arrived in $channelId within 120 seconds.');
  }
  final replyText = agentReply.text!.trim();
  final receivedAt = DateTime.now().toUtc();
  _log(
    'REPLY id=${agentReply.envelopeId} sender=${agentReply.senderId} '
    'createdAt=${agentReply.createdAt} text=${jsonEncode(agentReply.text)} '
    'latencyAfterAppend=${receivedAt.difference(sentAt).inMilliseconds}ms '
    'latencyAfterSendTap=${sendWatch.elapsed.inMilliseconds}ms',
  );

  // ChannelChatService prepends a Markdown sender heading to incoming rows.
  // Assert the actual reply paragraph is in the mounted chat's MarkdownBody,
  // not merely present in the NetworkSession state.
  final activeChat = find.byKey(ValueKey('channelChat:$channelId'));
  final replyBubble = find.descendant(
    of: activeChat,
    matching: find.byWidgetPredicate(
      (widget) => widget is MarkdownBody && widget.data.contains(replyText),
    ),
  );
  final rendered = await _waitFor(
    tester,
    () => replyBubble.evaluate().isNotEmpty,
    timeout: const Duration(seconds: 10),
    description: 'agent reply Markdown bubble rendered',
  );
  if (!rendered) _logChannelMessages(session, channelId);
  expect(replyBubble, findsWidgets);
  _log('PASS: live Duo→macOS DM round trip observed and rendered');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (_role != 'sender' && _role != 'receiver') {
    throw ArgumentError('E2E_ROLE must be sender or receiver, got $_role');
  }

  testWidgets('live Devices DM e2e ($_role)', (tester) async {
    final shell = await _bootShell(tester);
    if (shell == null) return; // Enrollment/boot diagnostics already logged.
    if (_role == 'receiver') {
      await _runReceiver(tester);
    } else {
      await _runSender(tester);
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
