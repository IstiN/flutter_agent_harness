/// Agent Wire Protocol v1 (issue #1101): the versioned JSON contract between
/// the fa engine and any host — events out, commands in — as a PURE mapping.
///
/// Zero transport code lives here: [AgentWireProtocol] converts between
/// Dart values ([AgentEvent], [WireCommand], handshake maps) and canonical
/// versioned frames (`{"v":1,"kind":...}`). Carrying frames is the host's
/// business — NDJSON over stdio/socket, platform channels, anything. The
/// framing rules (one JSON object per line — NDJSON, NOT JSONP) are in
/// `docs/wire-protocol.md` and pinned by [frameLine]/[parseLine].
///
/// Versioning discipline (backward-compat core):
/// - Additive-only within a major version. New kinds and new optional fields
///   are allowed; changing or removing existing ones requires `v` 2.
/// - Unknown FIELDS are ignored on decode (canonical re-encode drops them).
/// - Unknown KINDS degrade to the documented `unknown_event` /
///   `WireUnknownCommand` passthrough — the run stays alive (E3).
/// - Handshake: the client sends `hello {v, versions, caps}`, the server
///   answers `welcome {v, version, caps}` with the highest mutually
///   supported version; no overlap is a LOUD [WireVersionError].
/// - Every schema change ships golden fixtures for ALL live versions
///   (`test/wire/fixtures/v*/`); a change without fixtures fails CI.
///
/// Secrets (E4): fields listed in the secret-field registry
/// ([AgentWireProtocol.isSecretField]) carry credentials — `secret_response.
/// value`, `model_request.rawWireDump`. Hosts MUST pass frames through
/// [AgentWireProtocol.redactForLog] before logging or persisting them.
library;

import 'dart:convert';

import '../agent/agent_loop.dart';
import '../agent/tool_pairing.dart';
import '../approval/approval.dart';
import '../context.dart';
import '../tools/ask_tool.dart';
import '../tools/request_secret_tool.dart';
import '../trajectory/trajectory_blobs.dart';
import '../trajectory/trajectory_record.dart';
import '../types.dart';

/// The native protocol version this library speaks.
const int wireProtocolVersion = 1;

/// Every protocol version this library can encode and decode. Growing this
/// set (never shrinking) is how a new major ships alongside the old one.
const Set<int> supportedWireVersions = {1};

/// A protocol-level failure: malformed frame, bad handshake shape. Loud by
/// design — corrupt input at the engine boundary must not be papered over.
class WireProtocolException implements Exception {
  WireProtocolException(this.message);

  final String message;

  @override
  String toString() => 'WireProtocolException: $message';
}

/// The loud handshake failure when no protocol version overlaps.
class WireVersionError extends WireProtocolException {
  WireVersionError(super.message);
}

/// The result of decoding a wire event frame.
///
/// [KnownWireEvent] carries a reconstructed [AgentEvent];
/// [RequestWireEvent] is a host-interaction request (approval/ask/secret —
/// in-process these are callbacks, over the wire they are frames a host
/// answers with commands); [UnknownWireEvent] is the forward-compat
/// passthrough for kinds this library does not know — hosts render nothing
/// and keep the run alive.
sealed class DecodedWireEvent {
  DecodedWireEvent(this.raw);

  /// The raw frame as received (unknown fields preserved).
  final Map<String, dynamic> raw;
}

/// A frame decoded into a native [AgentEvent].
final class KnownWireEvent extends DecodedWireEvent {
  KnownWireEvent(this.event, super.raw);

  final AgentEvent event;
}

/// A host-interaction request frame: `approval_request`, `ask_request`, or
/// `secret_request`. The host answers with the matching `_response`
/// command, echoing [requestId].
final class RequestWireEvent extends DecodedWireEvent {
  RequestWireEvent({
    required this.kind,
    required this.requestId,
    this.approval,
    this.questions = const [],
    this.secretName,
    this.secretReason,
    required Map<String, dynamic> raw,
  }) : super(raw);

  /// `approval_request` | `ask_request` | `secret_request`.
  final String kind;

  /// Correlation id echoed by the host's response command.
  final String requestId;

  /// Native approval request payload ([kind] == `approval_request`).
  final ApprovalRequest? approval;

  /// Native questions ([kind] == `ask_request`).
  final List<AskQuestion> questions;

  /// Requested env var name ([kind] == `secret_request`).
  final String? secretName;

  /// Why the secret was requested ([kind] == `secret_request`).
  final String? secretReason;
}

/// A frame whose `kind` this library does not know (or `unknown_event`
/// itself): the passthrough keeps forward compatibility (E3).
final class UnknownWireEvent extends DecodedWireEvent {
  UnknownWireEvent(this.kind, super.raw);

  /// The original (unknown) kind name.
  final String kind;
}

/// The wire spelling of an [ApprovalDecision] (snake_case, like kinds).
const Map<ApprovalDecision, String> _decisionNames = {
  ApprovalDecision.approveOnce: 'approve_once',
  ApprovalDecision.approveAlways: 'approve_always',
  ApprovalDecision.deny: 'deny',
};

/// A host command: the wire form of the engine's input surface.
///
/// Typed subclasses carry the parsed payload; [WireUnknownCommand] is the
/// passthrough for commands a server does not know (it answers at its own
/// discretion — slice 1 only preserves the frame).
sealed class WireCommand {
  const WireCommand();

  /// The canonical frame for this command at [version].
  Map<String, dynamic> toJson({int version = wireProtocolVersion});
}

/// Start a run with [text] as the user prompt.
final class WirePromptCommand extends WireCommand {
  const WirePromptCommand(this.text);

  final String text;

  @override
  Map<String, dynamic> toJson({int version = wireProtocolVersion}) => {
    'v': version,
    'kind': 'prompt',
    'text': text,
  };
}

/// Inject [text] into the running turn (steering).
final class WireSteerCommand extends WireCommand {
  const WireSteerCommand(this.text);

  final String text;

  @override
  Map<String, dynamic> toJson({int version = wireProtocolVersion}) => {
    'v': version,
    'kind': 'steer',
    'text': text,
  };
}

/// Abort the active run (the wire form of the run's [CancelToken]).
final class WireAbortCommand extends WireCommand {
  const WireAbortCommand();

  @override
  Map<String, dynamic> toJson({int version = wireProtocolVersion}) => {
    'v': version,
    'kind': 'abort',
  };
}

/// Answer an `approval_request` with the user's [ApprovalDecision].
final class WireApprovalResponseCommand extends WireCommand {
  const WireApprovalResponseCommand({required this.id, required this.decision});

  /// The request id from the `approval_request` frame.
  final String id;

  final ApprovalDecision decision;

  @override
  Map<String, dynamic> toJson({int version = wireProtocolVersion}) => {
    'v': version,
    'kind': 'approval_response',
    'id': id,
    'decision': _decisionNames[decision],
  };
}

/// Answer an `ask_request`. [answers] `null` = the user cancelled.
final class WireAskResponseCommand extends WireCommand {
  const WireAskResponseCommand({required this.id, this.answers});

  /// The request id from the `ask_request` frame.
  final String id;

  /// One answer per question, in question order; `null` when cancelled.
  final List<AskAnswer>? answers;

  @override
  Map<String, dynamic> toJson({int version = wireProtocolVersion}) => {
    'v': version,
    'kind': 'ask_response',
    'id': id,
    'cancelled': answers == null,
    if (answers != null)
      'answers': [
        for (final answer in answers!)
          {
            if (answer.selected.isNotEmpty) 'selected': answer.selected,
            if (answer.freeText != null) 'freeText': answer.freeText,
          },
      ],
  };
}

/// Answer a `secret_request`. [result] `null` = the user declined.
///
/// E4: `result.value` is a SECRET-class field — hosts redact before logging.
final class WireSecretResponseCommand extends WireCommand {
  const WireSecretResponseCommand({required this.id, this.result});

  /// The request id from the `secret_request` frame.
  final String id;

  /// The granted credential; `null` when the user declined.
  final RequestSecretResult? result;

  @override
  Map<String, dynamic> toJson({int version = wireProtocolVersion}) => {
    'v': version,
    'kind': 'secret_response',
    'id': id,
    'granted': result != null,
    if (result != null) ...{
      'name': result!.name,
      'value': result!.value,
      'persisted': result!.persisted,
    },
  };
}

/// Session-level control. [op] is an open, additive registry (slice 1 pins
/// the frame shape, not an op set); [params] carries op arguments.
final class WireSessionControlCommand extends WireCommand {
  const WireSessionControlCommand({required this.op, this.params = const {}});

  final String op;

  final Map<String, dynamic> params;

  @override
  Map<String, dynamic> toJson({int version = wireProtocolVersion}) => {
    'v': version,
    'kind': 'session_control',
    'op': op,
    if (params.isNotEmpty) 'params': params,
  };
}

/// A command whose `kind` this library does not know: the passthrough form.
final class WireUnknownCommand extends WireCommand {
  const WireUnknownCommand({required this.kind, this.raw = const {}});

  /// The original (unknown) kind name.
  final String kind;

  /// The raw frame as received.
  final Map<String, dynamic> raw;

  @override
  Map<String, dynamic> toJson({int version = wireProtocolVersion}) => raw;
}

/// The pure event/command mapping and version negotiation for protocol v1.
class AgentWireProtocol {
  /// Creates a protocol speaking [version]. Unsupported versions are a
  /// construction-time [WireVersionError] — a host cannot half-configure
  /// the mapping.
  AgentWireProtocol({this.version = wireProtocolVersion}) {
    if (!supportedWireVersions.contains(version)) {
      throw WireVersionError(
        'unsupported wire protocol version $version '
        '(supported: ${supportedWireVersions.toList()..sort()})',
      );
    }
  }

  /// The negotiated version; every frame this instance produces carries it.
  final int version;

  // ---------------------------------------------------------------------------
  // Handshake
  // ---------------------------------------------------------------------------

  /// Builds the client `hello` frame.
  Map<String, dynamic> hello({
    List<int> versions = const [wireProtocolVersion],
    List<String> caps = const [],
  }) => {
    'v': version,
    'kind': 'hello',
    'versions': versions,
    if (caps.isNotEmpty) 'caps': caps,
  };

  /// Builds the server `welcome` frame for [negotiated].
  Map<String, dynamic> welcome({
    int negotiated = wireProtocolVersion,
    List<String> caps = const [],
  }) => {
    'v': version,
    'kind': 'welcome',
    'version': negotiated,
    if (caps.isNotEmpty) 'caps': caps,
  };

  /// Validates a client `hello` and negotiates the highest mutually
  /// supported version. The hello frame's own `v` participates in
  /// negotiation alongside the frame's `versions` array; negotiation is
  /// max-overlap and throws [WireVersionError] when there is no overlap
  /// (the loud unsupported-version error). [WireProtocolException] is
  /// thrown when the frame itself is malformed.
  static ({AgentWireProtocol protocol, Map<String, dynamic> welcome})
  acceptHello(Map<String, dynamic> helloFrame, {List<String> caps = const []}) {
    final kind = helloFrame['kind'];
    if (kind != 'hello') {
      throw WireProtocolException('expected a hello frame, got kind: $kind');
    }
    final rawVersion = helloFrame['v'];
    if (rawVersion is! int) {
      throw WireProtocolException('hello frame must carry an integer version');
    }
    final rawVersions = helloFrame['versions'];
    if (rawVersions is! List || rawVersions.isEmpty) {
      throw WireProtocolException(
        'hello frame must carry a non-empty versions array',
      );
    }
    for (final v in rawVersions) {
      if (v is! int) {
        throw WireProtocolException('hello versions must be integers');
      }
    }
    // The frame's own `v` caps only THIS frame's encoding: it is accepted
    // (and its unknown fields tolerated) but ignored for negotiation — a
    // client may send its hello in an older frame version while offering
    // newer ones. Negotiation reads the `versions` array; the single loud
    // gate is the overlap check in [negotiate].
    final negotiated = negotiate(rawVersions.cast<int>());
    final protocol = AgentWireProtocol(version: negotiated);
    return (
      protocol: protocol,
      welcome: protocol.welcome(negotiated: negotiated, caps: caps),
    );
  }

  /// The highest version from [clientVersions] this library supports.
  static int negotiate(List<int> clientVersions) {
    final overlap = clientVersions
        .where(supportedWireVersions.contains)
        .toList();
    if (overlap.isEmpty) {
      throw WireVersionError(
        'no protocol version overlap: client offers $clientVersions, '
        'server supports ${supportedWireVersions.toList()..sort()}',
      );
    }
    overlap.sort();
    return overlap.last;
  }

  // ---------------------------------------------------------------------------
  // Events (engine → host)
  // ---------------------------------------------------------------------------

  /// Encodes [event] into a canonical frame at this protocol's version.
  Map<String, dynamic> encodeEvent(AgentEvent event) {
    final frame = switch (event) {
      AgentStartEvent() => const <String, dynamic>{},
      AgentSettledEvent() => const <String, dynamic>{},
      TurnStartEvent() => const <String, dynamic>{},
      AgentEndEvent(:final messages) => {
        'messages': [
          for (final message in messages) _messageFrameJson(message),
        ],
      },
      TurnEndEvent(:final message, :final toolResults) => {
        'message': _messageFrameJson(message),
        'toolResults': [for (final result in toolResults) result.toJson()],
      },
      MessageStartEvent(:final message) => {
        'message': _messageFrameJson(message),
      },
      MessageEndEvent(:final message) => {
        'message': _messageFrameJson(message),
      },
      MessageUpdateEvent(:final message, :final assistantMessageEvent) => {
        // The partial snapshot IS `message`; the nested event adds only the
        // delta discriminator so frames stay compact.
        'message': _messageFrameJson(message),
        'event': encodeAssistantEvent(assistantMessageEvent),
      },
      ToolExecutionStartEvent(
        :final toolCallId,
        :final toolName,
        :final args,
        :final timestamp,
      ) =>
        {
          'toolCallId': toolCallId,
          'toolName': toolName,
          'args': args,
          'timestamp': timestamp.millisecondsSinceEpoch,
        },
      ToolExecutionUpdateEvent(
        :final toolCallId,
        :final toolName,
        :final args,
        :final partialResult,
      ) =>
        {
          'toolCallId': toolCallId,
          'toolName': toolName,
          'args': args,
          'partialResult': _encodeToolResult(partialResult),
        },
      ToolExecutionEndEvent(
        :final toolCallId,
        :final toolName,
        :final result,
        :final isError,
      ) =>
        {
          'toolCallId': toolCallId,
          'toolName': toolName,
          'result': _encodeToolResult(result),
          'isError': isError,
        },
      ModelRequestEvent(
        :final detail,
        :final promptBlob,
        :final manifestBlob,
        :final rawWireDump,
      ) =>
        {
          'detail': detail.toJson(),
          'promptBlob': ?promptBlob?.toJson(),
          'manifestBlob': ?manifestBlob?.toJson(),
          // SECRET-class (E4): redact via [redactForLog] before logging.
          'rawWireDump': ?rawWireDump,
        },
      ToolPairingRepairEvent(:final report, :final providerError) => {
        'report': _encodeRepairReport(report),
        'providerError': ?providerError,
      },
    };
    return {'v': version, 'kind': _kindOf(event), ...frame};
  }

  /// Encodes the nested provider-event discriminator of a
  /// `message_update` frame. `partial` is never duplicated here — the
  /// frame's `message` field IS the live partial.
  Map<String, dynamic> encodeAssistantEvent(AssistantMessageEvent event) =>
      switch (event) {
        StartEvent() => const {'kind': 'start'},
        TextStartEvent(:final contentIndex) => {
          'kind': 'text_start',
          'contentIndex': contentIndex,
        },
        TextDeltaEvent(:final contentIndex, :final delta) => {
          'kind': 'text_delta',
          'contentIndex': contentIndex,
          'delta': delta,
        },
        TextEndEvent(:final contentIndex, :final content) => {
          'kind': 'text_end',
          'contentIndex': contentIndex,
          'content': content,
        },
        ThinkingStartEvent(:final contentIndex) => {
          'kind': 'thinking_start',
          'contentIndex': contentIndex,
        },
        ThinkingDeltaEvent(:final contentIndex, :final delta) => {
          'kind': 'thinking_delta',
          'contentIndex': contentIndex,
          'delta': delta,
        },
        ThinkingEndEvent(:final contentIndex, :final content) => {
          'kind': 'thinking_end',
          'contentIndex': contentIndex,
          'content': content,
        },
        ToolCallStartEvent(:final contentIndex) => {
          'kind': 'tool_call_start',
          'contentIndex': contentIndex,
        },
        ToolCallDeltaEvent(:final contentIndex, :final delta) => {
          'kind': 'tool_call_delta',
          'contentIndex': contentIndex,
          'delta': delta,
        },
        ToolCallEndEvent(:final contentIndex, :final toolCall) => {
          'kind': 'tool_call_end',
          'contentIndex': contentIndex,
          'toolCall': toolCall.toJson(),
        },
        DoneEvent(:final reason) => {'kind': 'done', 'reason': reason.name},
        ErrorEvent(:final reason, :final retryAfter) => {
          'kind': 'error',
          'reason': reason.name,
          if (retryAfter != null) 'retryAfterMs': retryAfter.inMilliseconds,
        },
      };

  /// Builds the documented `unknown_event` passthrough frame — what a host
  /// emits when it must forward a frame it does not understand.
  Map<String, dynamic> encodeUnknownEvent({
    required String originalKind,
    Map<String, dynamic>? payload,
  }) => {
    'v': version,
    'kind': 'unknown_event',
    'originalKind': originalKind,
    'payload': payload ?? const {},
  };

  /// Per-kind event decoders — table-driven so the dispatch stays a tiny,
  /// fully-covered method (CRAP ratchet) and adding a kind is one map
  /// entry plus one small static method.
  static final Map<String, DecodedWireEvent Function(Map<String, dynamic>)>
  _eventDecoders = {
    'agent_start': _decodeAgentStart,
    'agent_settled': _decodeAgentSettled,
    'turn_start': _decodeTurnStart,
    'agent_end': _decodeAgentEnd,
    'turn_end': _decodeTurnEnd,
    'message_start': _decodeMessageStart,
    'message_end': _decodeMessageEnd,
    'message_update': _decodeMessageUpdate,
    'tool_execution_start': _decodeToolExecutionStart,
    'tool_execution_update': _decodeToolExecutionUpdate,
    'tool_execution_end': _decodeToolExecutionEnd,
    'model_request': _decodeModelRequest,
    'tool_pairing_repair': _decodeToolPairingRepair,
    'approval_request': _decodeApprovalRequest,
    'ask_request': _decodeAskRequest,
    'secret_request': _decodeSecretRequest,
  };

  /// Decodes an event frame. Unknown kinds (and `unknown_event` itself)
  /// return [UnknownWireEvent]; malformed known frames and unsupported
  /// versions throw [WireProtocolException]/[WireVersionError] — declared
  /// types are the only escapes (a malformed field must not surface as a
  /// raw [TypeError] from a nested `fromJson`).
  DecodedWireEvent decodeEvent(Map<String, dynamic> frame) {
    _requireFrameVersion(frame, 'event');
    final kind = _requireFrameKind(frame, 'event');
    final decoder = _eventDecoders[kind];
    try {
      if (decoder != null) return decoder(frame);
      if (kind == 'unknown_event') return _decodeUnknownEvent(frame);
      // Forward-compat passthrough (E3): unknown kinds keep the run alive.
      return UnknownWireEvent(kind, frame);
    } on TypeError catch (error) {
      throw WireProtocolException('malformed "$kind" event frame: $error');
    } on FormatException catch (error) {
      // Nested fromJson layers signal malformed payloads as FormatException
      // (e.g. an unknown message role) — surface the declared type.
      throw WireProtocolException('malformed "$kind" event frame: $error');
    }
  }

  static KnownWireEvent _decodeAgentStart(Map<String, dynamic> frame) =>
      KnownWireEvent(const AgentStartEvent(), frame);

  static KnownWireEvent _decodeAgentSettled(Map<String, dynamic> frame) =>
      KnownWireEvent(const AgentSettledEvent(), frame);

  static KnownWireEvent _decodeTurnStart(Map<String, dynamic> frame) =>
      KnownWireEvent(const TurnStartEvent(), frame);

  static KnownWireEvent _decodeAgentEnd(Map<String, dynamic> frame) =>
      KnownWireEvent(AgentEndEvent(_requireMessageList(frame)), frame);

  static KnownWireEvent _decodeTurnEnd(Map<String, dynamic> frame) {
    _requireKind(frame, 'turn_end');
    return KnownWireEvent(
      TurnEndEvent(
        message: _requireAssistant(frame['message'], 'turn_end'),
        toolResults: [
          for (final raw in _requireList(
            frame['toolResults'],
            'turn_end.toolResults',
          ))
            ToolResultMessage.fromJson(_requireMap(raw, 'toolResults[]')),
        ],
      ),
      frame,
    );
  }

  static KnownWireEvent _decodeMessageStart(Map<String, dynamic> frame) =>
      KnownWireEvent(
        MessageStartEvent(
          messageFromJson(
            _requireMap(frame['message'], 'message_start.message'),
          ),
        ),
        frame,
      );

  static KnownWireEvent _decodeMessageEnd(Map<String, dynamic> frame) =>
      KnownWireEvent(
        MessageEndEvent(
          messageFromJson(_requireMap(frame['message'], 'message_end.message')),
        ),
        frame,
      );

  static KnownWireEvent _decodeMessageUpdate(Map<String, dynamic> frame) {
    _requireKind(frame, 'message_update');
    final message = _requireAssistant(frame['message'], 'message_update');
    return KnownWireEvent(
      MessageUpdateEvent(
        message: message,
        assistantMessageEvent: _decodeAssistantEvent(
          _requireMap(frame['event'], 'message_update.event'),
          partial: message,
        ),
      ),
      frame,
    );
  }

  static KnownWireEvent _decodeToolExecutionStart(Map<String, dynamic> frame) {
    _requireKind(frame, 'tool_execution_start');
    return KnownWireEvent(
      ToolExecutionStartEvent(
        toolCallId: _requireString(frame['toolCallId'], 'toolCallId'),
        toolName: _requireString(frame['toolName'], 'toolName'),
        args: _requireMap(frame['args'], 'args'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          _requireInt(frame['timestamp'], 'timestamp'),
        ),
      ),
      frame,
    );
  }

  static KnownWireEvent _decodeToolExecutionUpdate(Map<String, dynamic> frame) {
    _requireKind(frame, 'tool_execution_update');
    return KnownWireEvent(
      ToolExecutionUpdateEvent(
        toolCallId: _requireString(frame['toolCallId'], 'toolCallId'),
        toolName: _requireString(frame['toolName'], 'toolName'),
        args: _requireMap(frame['args'], 'args'),
        partialResult: _decodeToolResult(
          _requireMap(frame['partialResult'], 'partialResult'),
        ),
      ),
      frame,
    );
  }

  static KnownWireEvent _decodeToolExecutionEnd(Map<String, dynamic> frame) {
    _requireKind(frame, 'tool_execution_end');
    return KnownWireEvent(
      ToolExecutionEndEvent(
        toolCallId: _requireString(frame['toolCallId'], 'toolCallId'),
        toolName: _requireString(frame['toolName'], 'toolName'),
        result: _decodeToolResult(_requireMap(frame['result'], 'result')),
        isError: _requireBool(frame['isError'], 'isError'),
      ),
      frame,
    );
  }

  static KnownWireEvent _decodeModelRequest(Map<String, dynamic> frame) {
    _requireKind(frame, 'model_request');
    return KnownWireEvent(
      ModelRequestEvent(
        detail: TrajectoryRequestDetail.fromJson(
          _requireMap(frame['detail'], 'detail'),
        ),
        promptBlob: _optionalBlob(
          frame['promptBlob'],
          TrajectoryPromptBlob.fromJson,
          'promptBlob',
        ),
        manifestBlob: _optionalBlob(
          frame['manifestBlob'],
          TrajectoryToolManifestBlob.fromJson,
          'manifestBlob',
        ),
        rawWireDump: _optionalString(frame['rawWireDump'], 'rawWireDump'),
      ),
      frame,
    );
  }

  /// Optional blob field: absent stays null, present-and-object decodes,
  /// anything else is a LOUD malformed frame (silent degradation would
  /// hide a producer bug behind an empty payload).
  static T? _optionalBlob<T>(
    Object? raw,
    T Function(Map<String, dynamic> json) fromJson,
    String field,
  ) {
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return fromJson(raw);
    throw WireProtocolException('field "$field" must be an object');
  }

  /// Optional string field: absent stays null, strings decode, anything
  /// else is loud.
  static String? _optionalString(Object? raw, String field) {
    if (raw == null) return null;
    if (raw is String) return raw;
    throw WireProtocolException('field "$field" must be a string');
  }

  /// Optional int field: absent stays null, ints decode, anything else is
  /// loud.
  static int? _optionalInt(Object? raw, String field) {
    if (raw == null) return null;
    if (raw is int) return raw;
    throw WireProtocolException('field "$field" must be an integer');
  }

  /// Optional list field: absent stays an empty list, lists decode,
  /// anything else is loud.
  static List<dynamic> _optionalList(Object? raw, String field) {
    if (raw == null) return const [];
    if (raw is List) return raw;
    throw WireProtocolException('field "$field" must be an array');
  }

  static KnownWireEvent _decodeToolPairingRepair(Map<String, dynamic> frame) {
    _requireKind(frame, 'tool_pairing_repair');
    return KnownWireEvent(
      ToolPairingRepairEvent(
        report: _decodeRepairReport(_requireMap(frame['report'], 'report')),
        providerError: frame['providerError'] as String?,
      ),
      frame,
    );
  }

  static UnknownWireEvent _decodeUnknownEvent(Map<String, dynamic> frame) =>
      UnknownWireEvent(
        frame['originalKind'] is String
            ? frame['originalKind'] as String
            : '<unnamed>',
        frame,
      );

  static RequestWireEvent _decodeApprovalRequest(Map<String, dynamic> frame) {
    _requireKind(frame, 'approval_request');
    return RequestWireEvent(
      kind: 'approval_request',
      requestId: _requireString(frame['id'], 'id'),
      approval: ApprovalRequest(
        toolName: _requireString(frame['toolName'], 'toolName'),
        tier: _decodeTier(_requireString(frame['tier'], 'tier')),
        arguments: _requireMap(frame['arguments'], 'arguments'),
        reason: _requireString(frame['reason'], 'reason'),
      ),
      raw: frame,
    );
  }

  static RequestWireEvent _decodeAskRequest(Map<String, dynamic> frame) {
    _requireKind(frame, 'ask_request');
    return RequestWireEvent(
      kind: 'ask_request',
      requestId: _requireString(frame['id'], 'id'),
      questions: [
        for (final raw in _requireList(
          frame['questions'],
          'ask_request.questions',
        ))
          _decodeQuestion(_requireMap(raw, 'questions[]')),
      ],
      raw: frame,
    );
  }

  static RequestWireEvent _decodeSecretRequest(Map<String, dynamic> frame) {
    _requireKind(frame, 'secret_request');
    return RequestWireEvent(
      kind: 'secret_request',
      requestId: _requireString(frame['id'], 'id'),
      secretName: _requireString(frame['name'], 'name'),
      secretReason: _requireString(frame['reason'], 'reason'),
      raw: frame,
    );
  }

  /// Encodes an in-process [ApprovalRequest] as an `approval_request` frame.
  Map<String, dynamic> encodeApprovalRequest({
    required String id,
    required ApprovalRequest request,
  }) => {
    'v': version,
    'kind': 'approval_request',
    'id': id,
    'toolName': request.toolName,
    'tier': request.tier.name,
    'arguments': request.arguments,
    'reason': request.reason,
  };

  /// Encodes an in-process `ask` callback's questions as an `ask_request`.
  Map<String, dynamic> encodeAskRequest({
    required String id,
    required List<AskQuestion> questions,
  }) => {
    'v': version,
    'kind': 'ask_request',
    'id': id,
    'questions': [for (final question in questions) _encodeQuestion(question)],
  };

  /// Encodes an in-process `request_secret` callback inputs as a
  /// `secret_request`.
  Map<String, dynamic> encodeSecretRequest({
    required String id,
    required String name,
    required String reason,
  }) => {
    'v': version,
    'kind': 'secret_request',
    'id': id,
    'name': name,
    'reason': reason,
  };

  // ---------------------------------------------------------------------------
  // Commands (host → engine)
  // ---------------------------------------------------------------------------

  /// Encodes a typed [command] into its canonical frame.
  Map<String, dynamic> encodeCommand(WireCommand command) =>
      command.toJson(version: version);

  /// Per-kind command decoders — same table-driven seam as events.
  static final Map<String, WireCommand Function(Map<String, dynamic>)>
  _commandDecoders = {
    'prompt': _decodePromptCommand,
    'steer': _decodeSteerCommand,
    'abort': _decodeAbortCommand,
    'approval_response': _decodeApprovalResponse,
    'ask_response': _decodeAskResponse,
    'secret_response': _decodeSecretResponse,
    'session_control': _decodeSessionControl,
  };

  /// Decodes a command frame. Unknown kinds return [WireUnknownCommand];
  /// malformed known frames and unsupported versions throw
  /// [WireProtocolException]/[WireVersionError] — declared types are the
  /// only escapes.
  WireCommand decodeCommand(Map<String, dynamic> frame) {
    _requireFrameVersion(frame, 'command');
    final kind = _requireFrameKind(frame, 'command');
    final decoder = _commandDecoders[kind];
    try {
      if (decoder != null) return decoder(frame);
      return WireUnknownCommand(kind: kind, raw: frame);
    } on TypeError catch (error) {
      throw WireProtocolException('malformed "$kind" command frame: $error');
    } on FormatException catch (error) {
      throw WireProtocolException('malformed "$kind" command frame: $error');
    }
  }

  static WireCommand _decodePromptCommand(Map<String, dynamic> frame) =>
      WirePromptCommand(_requireString(frame['text'], 'prompt.text'));

  static WireCommand _decodeSteerCommand(Map<String, dynamic> frame) =>
      WireSteerCommand(_requireString(frame['text'], 'steer.text'));

  static WireCommand _decodeAbortCommand(Map<String, dynamic> frame) =>
      const WireAbortCommand();

  static WireCommand _decodeApprovalResponse(Map<String, dynamic> frame) {
    _requireKind(frame, 'approval_response');
    return WireApprovalResponseCommand(
      id: _requireString(frame['id'], 'approval_response.id'),
      decision: _decodeDecision(
        _requireString(frame['decision'], 'approval_response.decision'),
      ),
    );
  }

  static WireCommand _decodeAskResponse(Map<String, dynamic> frame) {
    _requireKind(frame, 'ask_response');
    final cancelled = _requireBool(
      frame['cancelled'],
      'ask_response.cancelled',
    );
    return WireAskResponseCommand(
      id: _requireString(frame['id'], 'ask_response.id'),
      answers: cancelled
          ? null
          : [
              for (final raw in _requireList(
                frame['answers'],
                'ask_response.answers',
              ))
                _decodeAnswer(_requireMap(raw, 'answers[]')),
            ],
    );
  }

  static WireCommand _decodeSecretResponse(Map<String, dynamic> frame) {
    _requireKind(frame, 'secret_response');
    final granted = _requireBool(frame['granted'], 'secret_response.granted');
    return WireSecretResponseCommand(
      id: _requireString(frame['id'], 'secret_response.id'),
      result: granted
          ? RequestSecretResult(
              name: _requireString(frame['name'], 'secret_response.name'),
              // E4: stays SECRET-class through every decode.
              value: _requireString(frame['value'], 'secret_response.value'),
              persisted: _requireBool(
                frame['persisted'],
                'secret_response.persisted',
              ),
            )
          : null,
    );
  }

  static WireCommand _decodeSessionControl(Map<String, dynamic> frame) {
    _requireKind(frame, 'session_control');
    return WireSessionControlCommand(
      op: _requireString(frame['op'], 'session_control.op'),
      // The encoder omits `params` when empty - absent is the empty map,
      // a PRESENT non-map is loud.
      params: frame['params'] == null
          ? const {}
          : _requireMap(frame['params'], 'session_control.params'),
    );
  }

  // ---------------------------------------------------------------------------
  // E4: secrets
  // ---------------------------------------------------------------------------

  /// Top-level frame fields that carry credentials and MUST be redacted
  /// before logging or persisting. Additive-only: new secret fields join
  /// this registry, existing entries never move.
  static const Map<String, Set<String>> _secretFieldsByKind = {
    'secret_response': {'value'},
    'model_request': {'rawWireDump'},
  };

  /// Field names that are SECRET-class ANYWHERE in a frame (E4) — they only
  /// ever carry raw provider payloads. A name joins here deliberately:
  /// `rawBody` is the diagnostics-only 429 body ([RateLimitInfo.rawBody],
  /// issue #867) and must never survive a log/persist copy, even nested
  /// under `rateLimit` inside a message.
  static const Set<String> _secretFieldNamesAnywhere = {'rawBody'};

  /// Whether [field] of frame kind [kind] is SECRET-class (E4). The
  /// anywhere-rule is NOT dead for registry kinds: a `rawBody` under
  /// `secret_response` must still be marked, so the registry check and
  /// the anywhere-rule OR together (?? would fall through on `false`).
  static bool isSecretField(String kind, String field) =>
      (_secretFieldsByKind[kind]?.contains(field) ?? false) ||
      _secretFieldNamesAnywhere.contains(field);

  /// A message as it may appear ON the wire. E4: diagnostics-only secret
  /// payloads never ride protocol frames — [RateLimitInfo.rawBody] stays on
  /// the live in-process object (the engine may still log it through
  /// [redactForLog]) and is stripped from every embedded copy.
  static Map<String, dynamic> _messageFrameJson(Message message) {
    final json = message.toJson();
    if (message is! AssistantMessage) return json;
    final rateLimit = json['rateLimit'];
    if (rateLimit is Map<String, dynamic> && rateLimit['rawBody'] != null) {
      json['rateLimit'] = {...rateLimit}..remove('rawBody');
    }
    return json;
  }

  /// Deep-copies [frame] with every SECRET-class field replaced by the
  /// repo-standard `[REDACTED:<kind>]` marker — the layered redaction
  /// pipeline keys on the kind label, so nested maps inherit the frame's
  /// kind (unknown-kind frames mark as `[REDACTED:unknown]`). Use for
  /// LOGGING and PERSISTENCE copies only — the live frame keeps its
  /// values so the engine can work.
  static Map<String, dynamic> redactForLog(Map<String, dynamic> frame) =>
      _redactForLog(
        frame,
        frame['kind'] is String ? frame['kind'] as String : 'unknown',
      );

  static Map<String, dynamic> _redactForLog(
    Map<String, dynamic> frame,
    String kindLabel,
  ) {
    final secretFields = _secretFieldsByKind[kindLabel];
    return frame.map((key, value) {
      // NOTE: ?? binds looser than || in Dart - the registry check must be
      // parenthesized or a false `contains` short-circuits the anywhere-rule
      // for kinds that HAVE a registry entry (secret_response, model_request).
      if ((secretFields?.contains(key) ?? false) ||
          _secretFieldNamesAnywhere.contains(key)) {
        return MapEntry(key, '[REDACTED:$kindLabel]');
      }
      final valueCopy = switch (value) {
        Map<String, dynamic> map => _redactForLog(map, kindLabel),
        List<dynamic> list => [
          for (final item in list)
            item is Map<String, dynamic>
                ? _redactForLog(item, kindLabel)
                : item,
        ],
        _ => value,
      };
      return MapEntry(key, valueCopy);
    });
  }

  // ---------------------------------------------------------------------------
  // NDJSON framing
  // ---------------------------------------------------------------------------

  /// Frames one message as a single NDJSON line (UTF-8 JSON object plus
  /// `\n`). One object per line — NOT JSONP.
  static String frameLine(Map<String, dynamic> frame) =>
      '${jsonEncode(frame)}\n';

  /// Parses one NDJSON line. Blank lines return `null`; garbage throws
  /// [FormatException]; a line whose JSON is not an object throws
  /// [WireProtocolException].
  static Map<String, dynamic>? parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) {
      throw WireProtocolException('NDJSON line must hold a JSON object');
    }
    return decoded;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  String _kindOf(AgentEvent event) => switch (event) {
    AgentStartEvent() => 'agent_start',
    AgentEndEvent() => 'agent_end',
    AgentSettledEvent() => 'agent_settled',
    TurnStartEvent() => 'turn_start',
    TurnEndEvent() => 'turn_end',
    MessageStartEvent() => 'message_start',
    MessageUpdateEvent() => 'message_update',
    MessageEndEvent() => 'message_end',
    ToolExecutionStartEvent() => 'tool_execution_start',
    ToolExecutionUpdateEvent() => 'tool_execution_update',
    ToolExecutionEndEvent() => 'tool_execution_end',
    ModelRequestEvent() => 'model_request',
    ToolPairingRepairEvent() => 'tool_pairing_repair',
  };

  static AssistantMessageEvent _decodeAssistantEvent(
    Map<String, dynamic> encoded, {
    required AssistantMessage partial,
  }) {
    final kind = _requireString(encoded['kind'], 'event.kind');
    // Index-kinds must carry their content index loudly — defaulting to 0
    // would silently mis-render a producer bug.
    int index() => _requireInt(encoded['contentIndex'], 'event.contentIndex');
    return switch (kind) {
      'start' => StartEvent(partial: partial),
      'text_start' => TextStartEvent(contentIndex: index(), partial: partial),
      'text_delta' => TextDeltaEvent(
        contentIndex: index(),
        delta: _requireString(encoded['delta'], 'event.delta'),
        partial: partial,
      ),
      'text_end' => TextEndEvent(
        contentIndex: index(),
        content: _requireString(encoded['content'], 'event.content'),
        partial: partial,
      ),
      'thinking_start' => ThinkingStartEvent(
        contentIndex: index(),
        partial: partial,
      ),
      'thinking_delta' => ThinkingDeltaEvent(
        contentIndex: index(),
        delta: _requireString(encoded['delta'], 'event.delta'),
        partial: partial,
      ),
      'thinking_end' => ThinkingEndEvent(
        contentIndex: index(),
        content: _requireString(encoded['content'], 'event.content'),
        partial: partial,
      ),
      'tool_call_start' => ToolCallStartEvent(
        contentIndex: index(),
        partial: partial,
      ),
      'tool_call_delta' => ToolCallDeltaEvent(
        contentIndex: index(),
        delta: _requireString(encoded['delta'], 'event.delta'),
        partial: partial,
      ),
      'tool_call_end' => ToolCallEndEvent(
        contentIndex: index(),
        toolCall: ToolCall.fromJson(
          _requireMap(encoded['toolCall'], 'event.toolCall'),
        ),
        partial: partial,
      ),
      'done' => DoneEvent(
        reason: _decodeStopReason(_requireString(encoded['reason'], 'reason')),
        message: partial,
      ),
      'error' => ErrorEvent(
        reason: _decodeStopReason(_requireString(encoded['reason'], 'reason')),
        error: partial,
        retryAfter: encoded['retryAfterMs'] is int
            ? Duration(milliseconds: encoded['retryAfterMs'] as int)
            : null,
      ),
      _ => throw WireProtocolException('unknown nested event kind: $kind'),
    };
  }

  static Map<String, dynamic> _encodeToolResult(ToolExecutionResult result) => {
    'content': [for (final block in result.content) block.toJson()],
    'terminate': result.terminate,
  };

  static ToolExecutionResult _decodeToolResult(Map<String, dynamic> encoded) =>
      ToolExecutionResult(
        content: [
          for (final raw in (encoded['content'] as List?) ?? const <dynamic>[])
            ContentBlock.fromJson(_requireMap(raw, 'content[]')),
        ],
        terminate: encoded['terminate'] as bool? ?? false,
      );

  static Map<String, dynamic> _encodeRepairReport(
    ToolPairingRepairReport report,
  ) => {
    'droppedResultIds': report.droppedResultIds,
    'synthesizedResultIds': report.synthesizedResultIds,
    'renamedIds': [
      for (final rename in report.renamedIds)
        {'from': rename.from, 'to': rename.to},
    ],
  };

  static ToolPairingRepairReport _decodeRepairReport(
    Map<String, dynamic> encoded,
  ) => ToolPairingRepairReport(
    droppedResultIds: [
      for (final id in _requireList(
        encoded['droppedResultIds'],
        'tool_pairing_repair.report.droppedResultIds',
      ))
        id as String,
    ],
    synthesizedResultIds: [
      for (final id in _requireList(
        encoded['synthesizedResultIds'],
        'tool_pairing_repair.report.synthesizedResultIds',
      ))
        id as String,
    ],
    renamedIds: [
      for (final rename in _requireList(
        encoded['renamedIds'],
        'tool_pairing_repair.report.renamedIds',
      ))
        () {
          final entry = _requireMap(rename, 'renamedIds[]');
          return (
            from: _requireString(entry['from'], 'renamedIds[].from'),
            to: _requireString(entry['to'], 'renamedIds[].to'),
          );
        }(),
    ],
  );

  static Map<String, dynamic> _encodeQuestion(AskQuestion question) => {
    'question': question.question,
    'options': [
      for (final option in question.options)
        {
          'label': option.label,
          if (option.description != null) 'description': option.description,
        },
    ],
    'multiSelect': question.multiSelect,
    if (question.recommended != null) 'recommended': question.recommended,
  };

  static AskQuestion _decodeQuestion(Map<String, dynamic> encoded) =>
      AskQuestion(
        question: _requireString(
          encoded['question'],
          'ask_request.questions[].question',
        ),
        options: [
          for (final raw in _requireList(
            encoded['options'],
            'ask_request.questions[].options',
          ))
            _decodeOption(_requireMap(raw, 'options[]')),
        ],
        multiSelect: _requireBool(
          encoded['multiSelect'],
          'ask_request.questions[].multiSelect',
        ),
        recommended: _optionalInt(
          encoded['recommended'],
          'ask_request.questions[].recommended',
        ),
      );

  static AskOption _decodeOption(Map<String, dynamic> encoded) => AskOption(
    label: _requireString(encoded['label'], 'ask_request.options[].label'),
    description: _optionalString(
      encoded['description'],
      'ask_request.options[].description',
    ),
  );

  static AskAnswer _decodeAnswer(Map<String, dynamic> encoded) => AskAnswer(
    // The encoder omits `selected` for freeText-only answers - absent is
    // the domain default (empty), wrong-typed is loud.
    selected: [
      for (final label in _optionalList(
        encoded['selected'],
        'ask_response.answers[].selected',
      ))
        label as String,
    ],
    freeText: _optionalString(
      encoded['freeText'],
      'ask_response.answers[].freeText',
    ),
  );

  static ApprovalTier _decodeTier(String name) =>
      ApprovalTier.values.firstWhere(
        (tier) => tier.name == name,
        orElse: () =>
            throw WireProtocolException('unknown approval tier: $name'),
      );

  static ApprovalDecision _decodeDecision(String name) {
    for (final entry in _decisionNames.entries) {
      if (entry.value == name) return entry.key;
    }
    throw WireProtocolException('unknown approval decision: $name');
  }

  static StopReason _decodeStopReason(String name) =>
      StopReason.values.firstWhere(
        (reason) => reason.name == name,
        orElse: () => throw WireProtocolException('unknown stop reason: $name'),
      );

  // Loud required-field helpers: corrupt KNOWN frames must not silently
  // degrade into empty payloads.
  static void _requireKind(Map<String, dynamic> frame, String expected) {
    if (frame['kind'] != expected) {
      throw WireProtocolException('expected a $expected frame');
    }
  }

  /// Base-frame guard shared by every decoder: the frame must carry a
  /// version this library speaks. Unsupported versions are the LOUD
  /// [WireVersionError] (the library's declared version contract), not a
  /// generic protocol error.
  static void _requireFrameVersion(Map<String, dynamic> frame, String what) {
    final frameVersion = frame['v'];
    if (frameVersion is! int || !supportedWireVersions.contains(frameVersion)) {
      throw WireVersionError(
        '$what frame carries unsupported version $frameVersion '
        '(supported: ${supportedWireVersions.toList()..sort()})',
      );
    }
  }

  /// Base-frame guard shared by every decoder: the frame must name its kind.
  static String _requireFrameKind(Map<String, dynamic> frame, String what) {
    final kind = frame['kind'];
    if (kind is! String || kind.isEmpty) {
      throw WireProtocolException('$what frame is missing its kind');
    }
    return kind;
  }

  static String _requireString(Object? value, String field) {
    if (value is String && value.isNotEmpty) return value;
    throw WireProtocolException('field "$field" must be a non-empty string');
  }

  static int _requireInt(Object? value, String field) {
    if (value is int) return value;
    throw WireProtocolException('field "$field" must be an int');
  }

  static bool _requireBool(Object? value, String field) {
    if (value is bool) return value;
    throw WireProtocolException('field "$field" must be a bool');
  }

  static Map<String, dynamic> _requireMap(Object? value, String field) {
    if (value is Map<String, dynamic>) return value;
    throw WireProtocolException('field "$field" must be an object');
  }

  static List<dynamic> _requireList(Object? value, String field) {
    if (value is List) return value;
    throw WireProtocolException('field "$field" must be an array');
  }

  static AssistantMessage _requireAssistant(Object? value, String field) {
    final map = _requireMap(value, '$field.message');
    if (map['role'] != 'assistant') {
      throw WireProtocolException(
        'field "$field" must be an assistant message',
      );
    }
    return AssistantMessage.fromJson(map);
  }

  static List<Message> _requireMessageList(Map<String, dynamic> frame) {
    final raw = frame['messages'];
    if (raw is! List) {
      throw WireProtocolException(
        'field "agent_end.messages" must be an array',
      );
    }
    return [
      for (final message in raw)
        messageFromJson(_requireMap(message, 'messages[]')),
    ];
  }
}
