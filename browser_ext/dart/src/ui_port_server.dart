/// Service-worker side of `FaUiProtocol` (issue #30, "UI ↔ SW split", AC16
/// attach-replay). The UI lives in another JS context (side panel, full
/// tab); this server owns the border: N concurrent channels are
/// multiplexed over one agent (E8), inbound envelopes route into the
/// [UiHostConnector] seam (the slice of AgentHost the UI may drive), and
/// every host event is fanned out to all live channels AND appended to a
/// bounded ring, so a panel that closes and reopens catches up via
/// `attach` replay instead of losing the finished answer.
///
/// Pure Dart, zero IO, no timers: asynchrony comes only from the channels
/// themselves ([UiPortChannel.onMessage]); everything else is a
/// synchronous call, which makes the whole server fake-testable.
library;

import 'dart:async';

import 'ui_protocol.dart';
import 'ui_transport.dart';

/// The narrow slice of AgentHost the UI is allowed to drive. `agent_main`
/// implements this over the real [AgentHost]; tests substitute a fake.
abstract interface class UiHostConnector {
  /// Starts a turn (`prompt`) or steers the running one (`steer`) — the
  void sendUser(String text);
  void cancelTurn();

  /// Resolves a pending tool approval (`approval_response`).
  void decide(String approvalId, bool allow);

  /// Current host state snapshot (status events carry it verbatim).
  Map<String, dynamic> state();

  /// The live JSONL session id, or '' when none is open.
  String get sessionId;

  /// Stored settings (`settings_query`).
  Map<String, dynamic> settingsGet();

  /// Merges [settings] into the stored settings (`settings_put`).
  void settingsPut(Map<String, dynamic> settings);

  /// Known past sessions (`sessions_query`).
  List<Map<String, dynamic>> sessionsList();
}

/// Multiplexes UI channels onto one [UiHostConnector].
///
/// Capabilities advertised in `hello_ack`: stream, approvals, sessions,
/// settings. Prompt ids are deduped across ALL channels (a prompt replayed
/// after a reconnect runs once, E30); steer skips the deduper on purpose —
/// it mutates an already-running turn, and the same nudge arriving twice
/// is at worst a repeated instruction, not a second billed run.
final class UiPortServer {
  UiPortServer({required this.host, this.replayCap = 200});

  static const _serverCapabilities = [
    'stream',
    'approvals',
    'sessions',
    'settings',
  ];

  final UiHostConnector host;

  /// Ring bound for attach replay; the oldest event drops when exceeded.
  final int replayCap;

  /// Persists across channel lifecycles — dedup is the point (E30).
  final PromptDeduper _prompts = PromptDeduper();

  final _channels = <UiPortChannel>{};
  final _events = StreamController<UiProtocolMessage>.broadcast(sync: true);
  final _ring = <(int, Map<String, dynamic>)>[];
  int _seq = 0;

  /// Live channels (panel + full tab, E8).
  int get connections => _channels.length;

  /// Adopts [channel]: subscribes it to the host-event fan-out and to its
  /// own inbound envelopes until the channel closes (port drop — a dead
  /// MV3 worker's onDisconnect maps onto stream completion).
  void serve(UiPortChannel channel) {
    _channels.add(channel);
    final out = _events.stream.listen((msg) {
      if (!channel.isClosed) channel.send(msg.encode());
    });
    channel.onMessage.listen(
      (json) => _handle(channel, json),
      onDone: () {
        out.cancel();
        _channels.remove(channel);
      },
    );
  }

  /// The sink the host adapter feeds (same shapes AgentHost's
  /// [HostEventSink] emits). Each event is translated to its protocol
  /// envelope, appended to the replay ring, and broadcast to every live
  /// channel.
  void onHostEvent(Map<String, dynamic> event) {
    _ring.add((++_seq, event));
    while (_ring.length > replayCap) {
      _ring.removeAt(0);
    }
    _events.add(_translate(event));
  }

  /// Pushes [msg] to every live channel (host-adapter convenience for
  /// server-originated messages).
  void broadcast(UiProtocolMessage msg) {
    final json = msg.encode();
    for (final channel in _channels.toList()) {
      if (!channel.isClosed) channel.send(json);
    }
  }

  /// Verbatim relay (partial-first contract — the UI renders exactly what
  /// the loop produced), except `message_done` (drops its `type` tag into
  /// the dedicated envelope) and `approval_request` (structured fields).
  static UiProtocolMessage _translate(Map<String, dynamic> event) =>
      switch (event['type']) {
        'message_done' => MessageDoneMsg(message: {...event}..remove('type')),
        'approval_request' => ApprovalRequestMsg(
          id: event['id'] as String? ?? '',
          call: event['call'] is Map
              ? Map<String, dynamic>.from(event['call'] as Map)
              : const <String, dynamic>{},
          reason: event['reason'] as String? ?? '',
        ),
        _ => StreamMsg(event: event),
      };

  void _handle(UiPortChannel channel, Map<String, dynamic> json) {
    if (json['kind'] == 'error') return; // peer surfaced a failure: ignore
    final msg = UiProtocolMessage.decode(json);
    if (msg is ErrorMsg) {
      // Malformed peer bytes answer with a structured error ON THAT
      // CHANNEL; the server and every other channel stay untouched.
      _send(channel, ErrorMsg(code: 'malformed', message: msg.message));
      return;
    }
    switch (msg) {
      case final HelloMsg m:
        _hello(channel, m);
      case final AttachMsg m:
        _send(
          channel,
          AttachedMsg(
            sessionId: host.sessionId,
            replay: _replay(m.lastEventId),
          ),
        );
      case final PromptMsg m:
        if (_prompts.register(m.id)) host.sendUser(m.text);
      case final SteerMsg m:
        host.sendUser(m.text); // no dedup: steering is idempotent-ish
      case final CancelMsg _:
        host.cancelTurn();
      case final ApprovalResponseMsg m:
        host.decide(m.id, m.decision == 'allow');
      case final SessionsQueryMsg _:
        _send(channel, SessionsResultMsg(sessions: host.sessionsList()));
      case final SettingsQueryMsg _:
        _send(channel, SettingsResultMsg(settings: host.settingsGet()));
      case final SettingsPutMsg m:
        host.settingsPut(m.settings);
        _send(channel, SettingsResultMsg(settings: host.settingsGet()));
      default:
        break; // UI-bound kinds echoed back at us: ignore
    }
  }

  void _hello(UiPortChannel channel, HelloMsg msg) {
    final int agreed;
    try {
      agreed = negotiateVersion(uiProtocolVersion, msg.protoVersion);
    } on UiProtocolVersionError catch (error) {
      _channels.remove(channel);
      _send(channel, ErrorMsg(code: 'version', message: '$error'));
      channel.close();
      return;
    }
    _send(
      channel,
      HelloAckMsg(
        protoVersion: agreed,
        serverCapabilities: _serverCapabilities,
        sessionId: host.sessionId,
      ),
    );
  }

  /// Ring tail newer than [lastEventId] (a monotonic seq handed out at
  /// ring-append time, echoed back by the UI on the next attach). A null
  /// or unparsable id replays everything still resident.
  List<Map<String, dynamic>> _replay(String? lastEventId) {
    final after = lastEventId == null ? null : int.tryParse(lastEventId);
    return [
      for (final (seq, event) in _ring)
        if (after == null || seq > after) {'seq': seq, 'event': event},
    ];
  }

  void _send(UiPortChannel channel, UiProtocolMessage msg) {
    if (!channel.isClosed) channel.send(msg.encode());
  }
}
