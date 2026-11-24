/// `RequestSnapshot` (S0) — the last MAIN request "as sent" (GOAL #2394).
///
/// The hand-over call reads the exact prefix the session just warmed:
/// system prompt, tools and the message list of the last main send, plus
/// the record index the request's `m<seq>` tags resolve against. Every
/// main send overwrites the snapshot (last wins — the degenerate-empty
/// retry streams the same context); a snapshot is INVALID once it no
/// longer describes the live context:
///
/// - the session model changed (`prepareNextTurn` switched models — the
///   prefix a different model cached is nobody's warm bucket);
/// - a compaction run succeeded (the projection changed);
/// - the host switched branches / restored a checkpoint (the projection
///   was replaced — hosts call [RequestSnapshotStore.invalidate]).
///
/// A failed compaction run leaves the snapshot valid (nothing was
/// appended). S0 is a `Context`, not wire bytes: adapters rewrite the
/// payload — byte-identity of the prefix is asserted on the payload the
/// adapter serializes (`onPayload`), for the same model and compat.
///
/// Pure Dart — no IO.
library;

import '../context.dart';
import '../model.dart';
import '../types.dart';
import 'record_tag.dart';

/// How long a snapshot's cache bucket counts as warm (the report's
/// `bucket` signal — never a mode condition): Anthropic ephemeral
/// breakpoints and OpenAI prefix caches live ~5 minutes.
const Duration requestSnapshotBucketTtl = Duration(minutes: 5);

/// Whether [a] and [b] are the same served model (provider + id + base
/// URL) — the identity a snapshot's warm bucket is keyed by.
bool sameServedModel(Model a, Model b) =>
    a.provider == b.provider && a.id == b.id && a.baseUrl == b.baseUrl;

/// The last main request as sent. Immutable; [messages] is a private copy.
final class RequestSnapshot {
  /// Creates a snapshot; [messages] is copied, [seqMap] is the epoch the
  /// request's tags were stamped from.
  RequestSnapshot({
    required this.model,
    required List<Message> messages,
    this.systemPrompt,
    List<Tool> tools = const [],
    required this.seqMap,
    required this.sentAt,
    this.routing,
  }) : messages = List.unmodifiable(messages),
       tools = List.unmodifiable(tools);

  /// The model that served the request (`config.model` at send time —
  /// `prepareNextTurn` may have switched it away from the state model).
  final Model model;

  /// The request messages exactly as sent (post-transform — `time-left:`
  /// lines, pin carriers, pairing repairs included).
  final List<Message> messages;

  /// The request's system prompt.
  final String? systemPrompt;

  /// The request's tool manifest.
  final List<Tool> tools;

  /// The tag epoch the request was stamped from: seq → record resolution
  /// for the hand-over reply's hide list happens against THIS frozen
  /// index, never a fresh ledger (aliases drift under windowed storage
  /// and hard caps; the live edge — untaged — never names an alias).
  final TranscriptSeqMap seqMap;

  /// When the request was handed to the provider stream.
  final DateTime sentAt;

  /// The routing values the request rode (zone overrides), when any.
  final RequestRouting? routing;

  /// Whether this snapshot still describes the context [current] would
  /// send next: same served model.
  bool isValidFor(Model current) => sameServedModel(model, current);

  /// `warm` while the provider cache bucket the request wrote is still
  /// alive ([requestSnapshotBucketTtl]), else `cold` — a report signal.
  String bucket({DateTime? now}) =>
      (now ?? DateTime.now()).difference(sentAt) <= requestSnapshotBucketTtl
      ? 'warm'
      : 'cold';

  /// The stable record id behind alias [seq] on the frozen epoch index —
  /// `null` for unknown aliases (beyond the index, non-positive) and for
  /// records that never project into the model context (the hidden-range
  /// and pin bookkeeping records themselves).
  String? recordIdAt(int seq) {
    if (seq <= 0) return null;
    final record = seqMap.index.recordAt(seq);
    return record?.id;
  }

  /// The snapshot as the request context the hand-over call extends: a
  /// fresh `Context` over the stored copies (callers append their
  /// instruction to a COPY of the list).
  Context toContext({List<Message> extraMessages = const []}) => Context(
    systemPrompt: systemPrompt,
    messages: [...messages, ...extraMessages],
    tools: tools.isEmpty ? null : tools,
  );

  /// The prefix message count — the history breakpoint position the
  /// hand-over call passes to adapters that support `prefixLength` (the
  /// breakpoint sits on S0's last message, not on the instruction).
  int get prefixLength => messages.length;
}

/// The routing values a request rode.
final class RequestRouting {
  /// Creates the routing record.
  const RequestRouting({this.sessionId, this.cacheRetention});

  /// The prompt-cache affinity id (null = the provider default resolved
  /// at call time).
  final String? sessionId;

  /// The cache retention (`short`/`long`/`none`; null = provider default).
  final String? cacheRetention;
}

/// Last-wins holder of the session's [RequestSnapshot] — ONE per agent,
/// written at the main-send seam, read by the compaction host.
final class RequestSnapshotStore {
  RequestSnapshot? _snapshot;
  String? _invalidReason;

  /// The current snapshot, valid or not (hosts render its state).
  RequestSnapshot? get current => _snapshot;

  /// Why the last snapshot was invalidated, when a host/compaction run
  /// did it explicitly (model switches report through [validFor]).
  String? get invalidReason => _invalidReason;

  /// Records the latest main send (last wins, clears any invalidation).
  void capture(RequestSnapshot snapshot) {
    _snapshot = snapshot;
    _invalidReason = null;
  }

  /// Drops the snapshot — the projection it described is gone.
  void invalidate(String reason) {
    _snapshot = null;
    _invalidReason = reason;
  }

  /// The snapshot when it is still valid for [model], else `null`.
  RequestSnapshot? validFor(Model model) {
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.isValidFor(model)) return snapshot;
    return null;
  }
}
