/// `FaUiProtocol` — the extension-internal protocol between the Flutter UI
/// (side panel / full tab, an extension page) and the agent service worker
/// (issue #30, "UI ↔ SW split"). The worker owns the Agent loop and the
/// JSONL session; the UI lives in a different JS context, so everything
/// crossing that boundary is an explicit, versioned envelope:
///
/// - `hello`/`hello_ack` negotiate the wire version before anything else;
/// - `attach`/`attached` adopt a session (or ask for a fresh one) and
///   replay missed events — the UI can outlive a restarted worker;
/// - `prompt`/`steer`/`cancel` drive the loop; `stream`/`message_done`
///   carry the live partial message verbatim;
/// - `approval_request`/`approval_response` proxy tool approvals to the
///   human in front of the UI;
/// - `sessions_*`/`settings_*` are plain query/put pairs;
/// - `error` is the only failure channel: decode NEVER throws — any byte
///   garbage comes back as a structured `error`, so a desynced or hostile
///   peer degrades into a visible message instead of a dead listener.
///
/// Pure Dart, zero IO (dart2js compiles this file into both contexts);
/// transport glue (ports / worker messaging) lives outside.
library;

import 'dart:convert';

/// Wire protocol version implemented by this codec.
const int uiProtocolVersion = 2;

/// Oldest wire version still negotiable.
const int uiProtocolMinVersion = 1;

/// Thrown by [negotiateVersion] when no common supported version exists.
/// Carries both claims so the caller can render a precise refusal.
final class UiProtocolVersionError implements Exception {
  UiProtocolVersionError(this.mine, this.theirs);

  final int mine;
  final int theirs;

  @override
  String toString() =>
      'UiProtocolVersionError: ours $mine vs peer $theirs '
      '(both must be >= $uiProtocolMinVersion)';
}

/// Picks the version both sides speak: the minimum of the two claims when
/// both are within the supported range. A server answering a `hello`
/// echoes the agreed value as `hello_ack.protoVersion`. Version 0 predates
/// negotiation entirely (there is nothing to agree on), so it refuses
/// rather than guessing.
int negotiateVersion(int mine, int theirs) {
  if (mine < uiProtocolMinVersion || theirs < uiProtocolMinVersion) {
    throw UiProtocolVersionError(mine, theirs);
  }
  return mine < theirs ? mine : theirs;
}

/// Outgoing destination for relayed agent events (e.g. the port towards
/// the UI context).
typedef UiEventSink = void Function(Map<String, dynamic> event);

/// Base of the envelope hierarchy. [decode]/[decodeJson] are total: they
/// return an [ErrorMsg] (`unknown_kind` / `malformed`) instead of throwing
/// so the SW message listener can never be killed by its peer's bytes.
sealed class UiProtocolMessage {
  const UiProtocolMessage();

  /// Wire discriminator; exact strings are the protocol surface.
  String get kind;

  /// JSON-able map, ready for `jsonEncode` at the transport boundary.
  Map<String, dynamic> encode();

  /// Typed decode of an already-parsed envelope. Never throws: a missing
  /// or wrongly-typed required field, or a non-string `kind`, decodes to
  /// an `error` message (see [decodeJson] for the raw-string entry).
  static UiProtocolMessage decode(Map<String, dynamic> json) => _decode(json);

  /// Transport entry: decodes [raw] or answers with a structured
  /// `malformed` error — for ANY input, including byte garbage, arrays,
  /// bare strings and numbers. Total on purpose: the listener stays alive
  /// no matter what arrives.
  static UiProtocolMessage decodeJson(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return _decode(decoded);
      if (decoded is Map) return _decode(Map<String, dynamic>.from(decoded));
      return ErrorMsg(
        code: 'malformed',
        message: 'expected a JSON object, got ${decoded.runtimeType}',
      );
    } on FormatException catch (e) {
      return ErrorMsg(code: 'malformed', message: e.message);
    } on TypeError catch (e) {
      return ErrorMsg(code: 'malformed', message: e.toString());
    }
  }
}

/// UI → SW: opens the conversation; versions are negotiated before any
/// other traffic.
final class HelloMsg extends UiProtocolMessage {
  const HelloMsg({required this.protoVersion, required this.capabilities});

  final int protoVersion;
  final List<String> capabilities;

  @override
  String get kind => 'hello';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'protoVersion': protoVersion,
    'capabilities': capabilities,
  };
}

/// SW → UI: version agreement. `sessionId` is null when no session is
/// attached yet (the UI then follows up with `attach`).
final class HelloAckMsg extends UiProtocolMessage {
  const HelloAckMsg({
    required this.protoVersion,
    required this.serverCapabilities,
    required this.sessionId,
  });

  final int protoVersion;
  final List<String> serverCapabilities;
  final String? sessionId;

  @override
  String get kind => 'hello_ack';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'protoVersion': protoVersion,
    'serverCapabilities': serverCapabilities,
    'sessionId': sessionId,
  };
}

/// UI → SW: adopt [sessionId], or a fresh session when null. `lastEventId`
/// asks the worker to replay stream events missed while the worker was
/// restarting under a still-open UI.
final class AttachMsg extends UiProtocolMessage {
  const AttachMsg({required this.sessionId, required this.lastEventId});

  final String? sessionId;
  final String? lastEventId;

  @override
  String get kind => 'attach';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'sessionId': sessionId,
    'lastEventId': lastEventId,
  };
}

/// SW → UI: session adopted; `replay` carries the events newer than the
/// requested `lastEventId`, in order.
final class AttachedMsg extends UiProtocolMessage {
  const AttachedMsg({required this.sessionId, required this.replay});

  final String sessionId;
  final List<Map<String, dynamic>> replay;

  @override
  String get kind => 'attached';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'sessionId': sessionId,
    'replay': replay,
  };
}

/// UI → SW: start a turn. `id` is deduped SW-side ([PromptDeduper]) so a
/// prompt replayed after a reconnect runs once (edge E30).
final class PromptMsg extends UiProtocolMessage {
  const PromptMsg({required this.id, required this.text});

  final String id;
  final String text;

  @override
  String get kind => 'prompt';

  @override
  Map<String, dynamic> encode() => {'kind': kind, 'id': id, 'text': text};
}

/// UI → SW: mid-turn steering text for the running turn.
final class SteerMsg extends UiProtocolMessage {
  const SteerMsg({required this.text});

  final String text;

  @override
  String get kind => 'steer';

  @override
  Map<String, dynamic> encode() => {'kind': kind, 'text': text};
}

/// UI → SW: cancel the running turn.
final class CancelMsg extends UiProtocolMessage {
  const CancelMsg();

  @override
  String get kind => 'cancel';

  @override
  Map<String, dynamic> encode() => {'kind': kind};
}

/// SW → UI: one live agent event (text/thinking/toolcall delta …), passed
/// through verbatim — the partial message on screen must be exactly what
/// the loop produced.
final class StreamMsg extends UiProtocolMessage {
  const StreamMsg({required this.event});

  final Map<String, dynamic> event;

  @override
  String get kind => 'stream';

  @override
  Map<String, dynamic> encode() => {'kind': kind, 'event': event};
}

/// SW → UI: the turn's final assistant message.
final class MessageDoneMsg extends UiProtocolMessage {
  const MessageDoneMsg({required this.message});

  final Map<String, dynamic> message;

  @override
  String get kind => 'message_done';

  @override
  Map<String, dynamic> encode() => {'kind': kind, 'message': message};
}

/// SW → UI: a tool call awaits the human's decision.
final class ApprovalRequestMsg extends UiProtocolMessage {
  const ApprovalRequestMsg({
    required this.id,
    required this.call,
    required this.reason,
  });

  final String id;
  final Map<String, dynamic> call;
  final String reason;

  @override
  String get kind => 'approval_request';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'id': id,
    'call': call,
    'reason': reason,
  };
}

/// UI → SW: the human's decision; `updates` optionally amends the call
/// arguments before it runs (allow-with-edits).
final class ApprovalResponseMsg extends UiProtocolMessage {
  const ApprovalResponseMsg({
    required this.id,
    required this.decision,
    this.updates,
  });

  final String id;

  /// `allow` or `deny`.
  final String decision;
  final Map<String, dynamic>? updates;

  @override
  String get kind => 'approval_response';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'id': id,
    'decision': decision,
    'updates': updates,
  };
}

/// UI → SW: list known sessions.
final class SessionsQueryMsg extends UiProtocolMessage {
  const SessionsQueryMsg();

  @override
  String get kind => 'sessions_query';

  @override
  Map<String, dynamic> encode() => {'kind': kind};
}

/// SW → UI: answer to `sessions_query`.
final class SessionsResultMsg extends UiProtocolMessage {
  const SessionsResultMsg({required this.sessions});

  final List<Map<String, dynamic>> sessions;

  @override
  String get kind => 'sessions_result';

  @override
  Map<String, dynamic> encode() => {'kind': kind, 'sessions': sessions};
}

/// UI → SW: reset the live session — archive its JSONL, start a fresh one
/// (new id, empty transcript, same provider/approvals/tools). The SW
/// answers with the standard attach trio (AttachedMsg + ToolsStateMsg +
/// status) so the panel re-syncs exactly like on (re)attach.
final class SessionNewMsg extends UiProtocolMessage {
  const SessionNewMsg();

  @override
  String get kind => 'session_new';

  @override
  Map<String, dynamic> encode() => {'kind': kind};
}

/// UI → SW: open a past session (an archived JSONL) as the live one —
/// the current live session is archived first, the archive's transcript
/// is restored, and the standard attach trio answers so the panel
/// re-syncs onto the opened session.
final class SessionOpenMsg extends UiProtocolMessage {
  const SessionOpenMsg({required this.sessionId});

  final String sessionId;

  @override
  String get kind => 'session_open';

  @override
  Map<String, dynamic> encode() => {'kind': kind, 'sessionId': sessionId};
}

/// UI → SW: read settings.
final class SettingsQueryMsg extends UiProtocolMessage {
  const SettingsQueryMsg();

  @override
  String get kind => 'settings_query';

  @override
  Map<String, dynamic> encode() => {'kind': kind};
}

/// UI → SW: merge [settings] into the stored settings.
final class SettingsPutMsg extends UiProtocolMessage {
  const SettingsPutMsg({required this.settings});

  final Map<String, dynamic> settings;

  @override
  String get kind => 'settings_put';

  @override
  Map<String, dynamic> encode() => {'kind': kind, 'settings': settings};
}

/// SW → UI: current settings (answer to either settings message above).
final class SettingsResultMsg extends UiProtocolMessage {
  const SettingsResultMsg({required this.settings});

  final Map<String, dynamic> settings;

  @override
  String get kind => 'settings_result';

  @override
  Map<String, dynamic> encode() => {'kind': kind, 'settings': settings};
}

/// One tool's availability as the SW agent sees it (issue #34: the panel
/// Tools section renders the SW's registry, not a local one).
final class UiToolState {
  const UiToolState({required this.name, required this.enabled});

  final String name;
  final bool enabled;

  Map<String, dynamic> encode() => {'name': name, 'enabled': enabled};

  static UiToolState decode(Map<String, dynamic> json) => UiToolState(
    name: json['name'] as String,
    enabled: json['enabled'] as bool,
  );

  @override
  bool operator ==(Object other) =>
      other is UiToolState && other.name == name && other.enabled == enabled;

  @override
  int get hashCode => Object.hash(name, enabled);
}

List<UiToolState> _reqToolList(Map<String, dynamic> json, String field) {
  final v = json[field];
  if (v is List) {
    return [
      for (final e in v)
        UiToolState.decode(Map<String, dynamic>.from(e as Map)),
    ];
  }
  _bad('field "$field" must be a list of tool states');
}

/// SW → UI: the SW agent's tool list with enabled flags. Sent after
/// `attached` and after every applied `tools_put`.
final class ToolsStateMsg extends UiProtocolMessage {
  const ToolsStateMsg({required this.tools});

  final List<UiToolState> tools;

  @override
  String get kind => 'tools_state';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'tools': [for (final t in tools) t.encode()],
  };
}

/// UI → SW: apply per-tool enabled flags (the panel Tools toggles). The
/// SW unregisters disabled tools from the live agent and answers with a
/// fresh `tools_state`.
final class ToolsPutMsg extends UiProtocolMessage {
  const ToolsPutMsg({required this.tools});

  final List<UiToolState> tools;

  @override
  String get kind => 'tools_put';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'tools': [for (final t in tools) t.encode()],
  };
}

/// UI → SW: a one-shot host-capability request (`ext_request`) — a small
/// op surface ONLY the extension page may use, answered by the SW with
/// [ExtResultMsg]: `cookies.get_all` (the user's live cookie jar for an
/// origin — CodeMie's cookie auth without any localhost SSO dance),
/// `fetch` (an SW-relayed HTTP call; MV3 + `<all_urls>` host permissions
/// bypass CORS, so provider endpoints unreachable from a web page work),
/// `tabs.create` (open the provider's login page for an interactive
/// sign-in).
final class ExtRequestMsg extends UiProtocolMessage {
  const ExtRequestMsg({required this.id, required this.op, this.params});

  final String id;
  final String op;
  final Map<String, dynamic>? params;

  @override
  String get kind => 'ext_request';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'id': id,
    'op': op,
    if (params != null) 'params': params,
  };
}

/// SW → UI: the answer to [ExtRequestMsg], matched by [id]. `ok: false`
/// carries a human-readable [error]; the op surface is trusted (extension
/// page only) but every op still validates its params.
final class ExtResultMsg extends UiProtocolMessage {
  const ExtResultMsg({
    required this.id,
    required this.ok,
    this.data,
    this.error,
  });

  final String id;
  final bool ok;
  final Map<String, dynamic>? data;
  final String? error;

  @override
  String get kind => 'ext_result';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'id': id,
    'ok': ok,
    if (data != null) 'data': data,
    if (error != null) 'error': error,
  };
}

/// UI → SW: link keepalive. An open MV3 port does NOT keep the service
/// worker alive — only events reset the 30s idle timer — so an attached
/// panel pings on a fixed cadence to stay connected instead of flapping
/// through reconnect cycles. The SW answers [PongMsg]; either direction
/// alone is enough to reset the timer, the reply just confirms the link.
final class PingMsg extends UiProtocolMessage {
  const PingMsg();

  @override
  String get kind => 'ping';

  @override
  Map<String, dynamic> encode() => {'kind': kind};
}

/// SW → UI: the keepalive reply.
final class PongMsg extends UiProtocolMessage {
  const PongMsg();

  @override
  String get kind => 'pong';

  @override
  Map<String, dynamic> encode() => {'kind': kind};
}

/// The only failure channel — also what [UiProtocolMessage.decode] answers
/// with for `unknown_kind` and `malformed` inputs.
final class ErrorMsg extends UiProtocolMessage {
  const ErrorMsg({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String get kind => 'error';

  @override
  Map<String, dynamic> encode() => {
    'kind': kind,
    'code': code,
    'message': message,
  };
}

/// Internal control-flow signal: field-level failures funnel into a
/// structured `malformed` [ErrorMsg] at the single catch in [_decode].
/// Never escapes the public API.
class _Malformed implements Exception {
  const _Malformed(this.detail);

  final String detail;
}

Never _bad(String detail) => throw _Malformed(detail);

bool _reqBool(Map<String, dynamic> json, String field) {
  final v = json[field];
  if (v is bool) return v;
  _bad('field "$field" must be a bool');
}

String _reqStr(Map<String, dynamic> json, String field) {
  final v = json[field];
  if (v is String) return v;
  _bad('field "$field" must be a string');
}

int _reqInt(Map<String, dynamic> json, String field) {
  final v = json[field];
  if (v is int) return v;
  _bad('field "$field" must be an int');
}

List<String> _reqStrList(Map<String, dynamic> json, String field) {
  final v = json[field];
  if (v is List && v.every((e) => e is String)) return List<String>.from(v);
  _bad('field "$field" must be a list of strings');
}

Map<String, dynamic> _reqMap(Map<String, dynamic> json, String field) {
  final v = json[field];
  if (v is Map) return Map<String, dynamic>.from(v);
  _bad('field "$field" must be an object');
}

List<Map<String, dynamic>> _reqMapList(
  Map<String, dynamic> json,
  String field,
) {
  final v = json[field];
  if (v is List && v.every((e) => e is Map)) {
    return [for (final e in v) Map<String, dynamic>.from(e)];
  }
  _bad('field "$field" must be a list of objects');
}

String? _optStr(Map<String, dynamic> json, String field) {
  final v = json[field];
  if (v == null) return null;
  if (v is String) return v;
  _bad('field "$field" must be a string when present');
}

Map<String, dynamic>? _optMap(Map<String, dynamic> json, String field) {
  final v = json[field];
  if (v == null) return null;
  if (v is Map) return Map<String, dynamic>.from(v);
  _bad('field "$field" must be an object when present');
}

UiProtocolMessage _decode(Map<String, dynamic> json) {
  try {
    final kind = json['kind'];
    if (kind is! String) _bad('missing or non-string "kind"');
    switch (kind) {
      case 'hello':
        return HelloMsg(
          protoVersion: _reqInt(json, 'protoVersion'),
          capabilities: _reqStrList(json, 'capabilities'),
        );
      case 'hello_ack':
        return HelloAckMsg(
          protoVersion: _reqInt(json, 'protoVersion'),
          serverCapabilities: _reqStrList(json, 'serverCapabilities'),
          sessionId: _optStr(json, 'sessionId'),
        );
      case 'attach':
        return AttachMsg(
          sessionId: _optStr(json, 'sessionId'),
          lastEventId: _optStr(json, 'lastEventId'),
        );
      case 'attached':
        return AttachedMsg(
          sessionId: _reqStr(json, 'sessionId'),
          replay: _reqMapList(json, 'replay'),
        );
      case 'prompt':
        return PromptMsg(id: _reqStr(json, 'id'), text: _reqStr(json, 'text'));
      case 'steer':
        return SteerMsg(text: _reqStr(json, 'text'));
      case 'cancel':
        return const CancelMsg();
      case 'stream':
        return StreamMsg(event: _reqMap(json, 'event'));
      case 'message_done':
        return MessageDoneMsg(message: _reqMap(json, 'message'));
      case 'approval_request':
        return ApprovalRequestMsg(
          id: _reqStr(json, 'id'),
          call: _reqMap(json, 'call'),
          reason: _reqStr(json, 'reason'),
        );
      case 'approval_response':
        return ApprovalResponseMsg(
          id: _reqStr(json, 'id'),
          decision: _reqStr(json, 'decision'),
          updates: _optMap(json, 'updates'),
        );
      case 'sessions_query':
        return const SessionsQueryMsg();
      case 'sessions_result':
        return SessionsResultMsg(sessions: _reqMapList(json, 'sessions'));
      case 'session_new':
        return const SessionNewMsg();
      case 'session_open':
        return SessionOpenMsg(sessionId: _reqStr(json, 'sessionId'));
      case 'settings_query':
        return const SettingsQueryMsg();
      case 'settings_put':
        return SettingsPutMsg(settings: _reqMap(json, 'settings'));
      case 'settings_result':
        return SettingsResultMsg(settings: _reqMap(json, 'settings'));
      case 'tools_state':
        return ToolsStateMsg(tools: _reqToolList(json, 'tools'));
      case 'tools_put':
        return ToolsPutMsg(tools: _reqToolList(json, 'tools'));
      case 'ext_request':
        return ExtRequestMsg(
          id: _reqStr(json, 'id'),
          op: _reqStr(json, 'op'),
          params: _optMap(json, 'params'),
        );
      case 'ext_result':
        return ExtResultMsg(
          id: _reqStr(json, 'id'),
          ok: _reqBool(json, 'ok'),
          data: _optMap(json, 'data'),
          error: _optStr(json, 'error'),
        );
      case 'ping':
        return const PingMsg();
      case 'pong':
        return const PongMsg();
      case 'error':
        return ErrorMsg(
          code: _reqStr(json, 'code'),
          message: _reqStr(json, 'message'),
        );
      default:
        return ErrorMsg(
          code: 'unknown_kind',
          message: 'no such message kind: $kind',
        );
    }
  } on _Malformed catch (e) {
    return ErrorMsg(code: 'malformed', message: e.detail);
  }
}

/// Verbatim stream-event relay, SW side: the Agent's live event map enters
/// [emit] and leaves through [sink] as the SAME reference — no rebuild, no
/// re-sort — because the UI renders the partial message and any reshuffle
/// is a visible diff for zero gain. Buffering/retry lives in session
/// replay (`attach.lastEventId`), not here.
/// ponytail: a forwarded reference; an LRU ring covers the deduper.
final class EventRelay {
  EventRelay({required this.sink});

  final UiEventSink sink;

  void emit(Map<String, dynamic> agentEvent) => sink(agentEvent);
}

/// SW-side prompt-id dedup (edge E30): a prompt replayed after a UI
/// reconnect must run once. Ids match by equality regardless of arrival
/// order, so a re-sent older prompt is still recognized. Bounded LRU:
/// once [capacity] ids are resident the oldest leaves the window — a
/// prompt replayed after a full window is by contract old enough to
/// re-process. A repeat refreshes recency.
/// ponytail: insertion-ordered set as LRU ring, same pattern as the
/// dap_frames MailDeduper.
final class PromptDeduper {
  PromptDeduper({this.capacity = 1024});

  final int capacity;
  final _seen = <String>{};

  /// True the first time [promptId] is seen (now recorded), false on any
  /// repeat.
  bool register(String promptId) {
    if (!_seen.add(promptId)) {
      _seen
        ..remove(promptId)
        ..add(promptId); // refresh recency
      return false;
    }
    if (_seen.length >= capacity) _seen.remove(_seen.first);
    return true;
  }
}
