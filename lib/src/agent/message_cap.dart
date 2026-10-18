/// gh-1680 — adaptive per-model message-cap handling.
///
/// Some providers enforce a hard per-request cap on the number of messages
/// in one request, independent of token count (incident: a session wedged
/// forever on the provider's `array length N exceeds limit M` refusal
/// while token-healthy). This module is the repair path:
///
/// - **Discovery** — the classifier lives in `overflow.dart`
///   ([classifyMessageCapError]); these classes only CARRY its verdict.
/// - **Learned-cap store** ([ModelCapsStore]) — a per-model record keyed
///   `(provider, modelId) → maxMessages`, persisted next to the
///   per-provider `model_cache.json` lifecycle. NO provider/model table is
///   hardcoded anywhere: the only built-in knowledge is the error-text
///   classifier (AC5).
/// - **Policy** ([MessageCapPolicy]) — the loop-facing seam: the cap for
///   the current model, and learning from a refusal. `null` policy =
///   byte-identical to the pre-gh-1680 loop (AC8).
/// - **Coalesce** ([coalesceMessagesForCap]) — merges whole tool-call/
///   result pairs and old turns older than the newest user message into
///   compact carrier messages on the OUTBOUND payload only (the session
///   JSONL stays byte-identical, AC7); pairing invariants hold on the wire
///   (AC6).
library;

import 'dart:convert';
import 'dart:io' show File;

import '../context.dart';
import '../model.dart' show Model;
import '../overflow.dart' show MessageCapRefusal;
import '../types.dart' show AssistantMessage, Message, ToolCall;
import 'tool_pairing.dart' show repairToolPairing;

/// The default margin between the live message count and the learned cap
/// at which the pre-emptive compaction trigger fires (open question 1 on
/// the card: `cap − margin`). 16 messages ≈ several turns of tool-call +
/// result growth at the observed ~7 calls/min — big enough that a burst of
/// turns between the trigger and the request cannot re-wedge the run,
/// small enough not to compact wastefully early.
const int kMessageCapDefaultMargin = 16;

/// The loop-facing gh-1680 policy: what the current model's learned cap is
/// (null = no known cap → byte-identical behavior), and how a provider
/// refusal is recorded. Implemented by [ModelCapsStore]; hosts may wrap it
/// (e.g. to layer a config-pinned override on top, the card's second tier).
abstract class MessageCapPolicy {
  /// The learned (or pinned) per-request message cap for [model], or null
  /// when nothing is known — no cap, or a cap-unknown model that has not
  /// refused yet this session.
  int? learnedCapFor(Model model);

  /// Records a classified cap refusal for [model]. Implementations should
  /// persist the learned value so the NEXT process boots with it (AC2).
  /// A refusal with an unparseable limit (cap-unknown) must never UNLEARN
  /// an existing numeric cap (a differently-shaped retry of the same
  /// refusal would otherwise erase the knowledge).
  void learnFromRefusal(Model model, MessageCapRefusal refusal);
}

/// One learned record: the cap limit when parsed, or a cap-unknown flag
/// (the model refused but the error carried no number — edge E1).
final class ModelCapRecord {
  const ModelCapRecord({this.maxMessages, this.capUnknown = false});

  factory ModelCapRecord.fromJson(Map<String, dynamic> json) => ModelCapRecord(
    maxMessages: json['maxMessages'] is int ? json['maxMessages'] as int : null,
    capUnknown: json['capUnknown'] == true,
  );

  /// The learned per-request message cap; null when unparseable.
  final int? maxMessages;

  /// Whether the model is flagged cap-unknown (refusal without a number).
  final bool capUnknown;

  Map<String, dynamic> toJson() => {
    if (maxMessages != null) 'maxMessages': maxMessages,
    if (capUnknown) 'capUnknown': true,
  };
}

/// The learned per-model message-cap store (gh-1680, AC2).
///
/// Keyed by `(provider, modelId)` — the cap is a property of the MODEL, not
/// the endpoint (one gateway hosts many models with different limits, so
/// per-endpoint keys would collide; edge E5). Entries persist across
/// restarts through [load]/[persist] on a JSON file (the CLI uses
/// `<homeDir>/.fah/model_caps.json`, a sibling of `model_cache.json`).
///
/// In-memory only until [persist] is called; a failed persist never throws
/// (best-effort, like the model cache). No provider/model identifiers are
/// compiled in — the store starts empty and learns exclusively from
/// classified refusals.
final class ModelCapsStore implements MessageCapPolicy {
  ModelCapsStore({Map<String, ModelCapRecord>? initial})
    : _caps = {...?initial};

  /// Parses the store's JSON form (see [toJson]); a malformed payload
  /// yields an empty store rather than throwing (boot must never fail on
  /// a corrupt sidecar).
  factory ModelCapsStore.fromJson(Map<String, dynamic> json) {
    final caps = <String, ModelCapRecord>{};
    for (final entry in json.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        caps[entry.key] = ModelCapRecord.fromJson(value);
      }
    }
    return ModelCapsStore(initial: caps);
  }

  final Map<String, ModelCapRecord> _caps;

  /// The compound key: one identity per (provider, modelId) so caps never
  /// collide across providers serving the same model id (E5).
  static String keyOf(String provider, String modelId) =>
      '$provider\u{001F}$modelId';

  /// Every learned record, keyed by [keyOf] — introspection for hosts.
  Map<String, ModelCapRecord> get records => Map.unmodifiable(_caps);

  /// The record for one model identity, or null when nothing is learned.
  ModelCapRecord? recordFor(String provider, String modelId) =>
      _caps[keyOf(provider, modelId)];

  /// The learned cap for one model identity (null = unknown/none).
  int? capFor(String provider, String modelId) =>
      recordFor(provider, modelId)?.maxMessages;

  /// Whether the model is flagged cap-unknown (E1: a refusal without a
  /// parseable number was seen and no numeric cap has been learned since).
  bool isCapUnknown(String provider, String modelId) {
    final record = recordFor(provider, modelId);
    return record != null && record.maxMessages == null && record.capUnknown;
  }

  @override
  int? learnedCapFor(Model model) => capFor(model.provider, model.id);

  @override
  void learnFromRefusal(Model model, MessageCapRefusal refusal) {
    final key = keyOf(model.provider, model.id);
    final existing = _caps[key];
    if (refusal.maxMessages != null) {
      // (Re-)learn the numeric cap — also the stale-cap refresh path (E4:
      // a provider that changed its limit re-teaches the new M).
      _caps[key] = ModelCapRecord(maxMessages: refusal.maxMessages);
      return;
    }
    // Cap-unknown refusal: flag it ONLY when no numeric cap is on record —
    // never unlearn a numeric cap from a differently-shaped retry.
    if (existing == null || existing.maxMessages == null) {
      _caps[key] = const ModelCapRecord(capUnknown: true);
    }
  }

  /// Second tier (config override): pins a cap for one model identity,
  /// overriding any learned value. A pinned cap survives learned refusals
  /// only until the pin is removed — [learnFromRefusal] overwrites records,
  /// so hosts layering pins should consult them BEFORE the learned value
  /// (see [learnedCapOr]).
  void pin(String provider, String modelId, int maxMessages) {
    _caps[keyOf(provider, modelId)] = ModelCapRecord(
      maxMessages: maxMessages,
    );
  }

  /// Removes a pin/learned record for one model identity.
  void remove(String provider, String modelId) =>
      _caps.remove(keyOf(provider, modelId));

  /// The effective cap for one model identity: [pinned] (config override)
  /// wins, then the learned record.
  static int? learnedCapOr(ModelCapRecord? learned, int? pinned) =>
      pinned ?? learned?.maxMessages;

  /// Serializes the whole store; empty stores serialize to `{}`.
  Map<String, dynamic> toJson() => {
    for (final entry in _caps.entries) entry.key: entry.value.toJson(),
  };

  /// Loads the store from [path]; a missing/corrupt file yields an empty
  /// store (boot never fails on a sidecar). Best-effort by contract.
  static ModelCapsStore load(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return ModelCapsStore();
      final text = file.readAsStringSync();
      if (text.isEmpty) return ModelCapsStore();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return ModelCapsStore();
      return ModelCapsStore.fromJson(decoded);
    } on Object {
      return ModelCapsStore();
    }
  }

  /// Persists the store to [path] (creating the parent directory).
  /// Best-effort: a failed write leaves the in-memory store intact.
  void persist(String path) {
    try {
      final file = File(path);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(toJson()));
    } on Object {
      // Best-effort persistence, mirroring the model-cache lifecycle.
    }
  }
}

/// Whether the live [messageCount] is at/above the pre-emptive trigger for
/// a learned cap: `count ≥ cap − margin` (AC4). A null/unknown cap never
/// triggers (AC8); a margin of zero means "at the cap itself".
bool messageCapTriggerReached(int messageCount, int? learnedCap,
        {int margin = kMessageCapDefaultMargin}) =>
    learnedCap != null && messageCount >= learnedCap - margin;

/// gh-1680 AC6/E2/E3: coalesces the OUTBOUND message list so its length
/// approaches [targetMessageCount], merging whole tool-call/result pairs
/// and old turns older than the newest user message into compact carrier
/// messages.
///
/// Invariants (asserted by tests):
/// - The system prompt is not in this list (it rides
///   [Context.systemPrompt]); the newest user message is NEVER merged or
///   dropped, and nothing after it is touched.
/// - Only WHOLE tool-call/result groups go: an assistant message with
///   tool calls and every result answering those calls merge together, so
///   no orphaned result or unanswered call can appear on the wire. The
///   result is still run through [repairToolPairing] as the belt on the
///   suspenders (pre-broken input pairing is repaired, never propagated).
/// - The input list is never mutated (outbound-only; the session JSONL
///   stays byte-identical, AC7).
///
/// Returns the input list unchanged when it already fits [target] (or
/// nothing is droppable — the newest user turn alone is over target, E3).
List<Message> coalesceMessagesForCap(
  List<Message> messages, {
  required int targetMessageCount,
}) {
  if (messages.length <= targetMessageCount) return messages;
  // The cut: the newest user message stays verbatim, so the droppable
  // region is [0, newestUserIndex). With no user message at all (a pure
  // tool-call transcript), the LAST message is kept instead — a request
  // must never end up empty (E3).
  var newestUserIndex = -1;
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i] is UserMessage) {
      newestUserIndex = i;
      break;
    }
  }
  final regionEnd = newestUserIndex >= 0 ? newestUserIndex : messages.length - 1;
  if (regionEnd <= 0) return messages; // Nothing droppable (E2/E3).

  // Group the droppable region into pairing-safe units: a tool group is an
  // assistant message carrying tool calls plus the ToolResultMessages
  // answering them; every other message is its own unit.
  final units = <List<Message>>[];
  var i = 0;
  while (i < regionEnd) {
    final message = messages[i];
    final calls = message is AssistantMessage
        ? message.content.whereType<ToolCall>().toList()
        : const <ToolCall>[];
    if (calls.isEmpty) {
      units.add([message]);
      i++;
      continue;
    }
    final answered = calls.map((call) => call.id).toSet();
    final group = <Message>[message];
    var j = i + 1;
    while (j < messages.length && answered.isNotEmpty) {
      final next = messages[j];
      if (next is ToolResultMessage && answered.remove(next.toolCallId)) {
        group.add(next);
        j++;
      } else {
        break;
      }
    }
    units.add(group);
    i = j;
  }

  // Merge each unit into one user-role carrier; carriers still over the
  // target then merge together (oldest first) until one remains or the
  // count fits.
  final carriers = [for (final unit in units) _carrierOf(unit)];
  var merged = [...carriers, ...messages.sublist(regionEnd)];
  while (merged.length > targetMessageCount && carriers.length > 1) {
    final first = carriers.removeAt(0);
    final second = carriers.removeAt(0);
    carriers.insert(
      0,
      UserMessage.text('${_carrierTextOf(first)}\n${_carrierTextOf(second)}'),
    );
    merged = [...carriers, ...messages.sublist(regionEnd)];
  }
  // Over target with a single carrier left: nothing more is droppable
  // without touching the newest turn (E2/E3) — the wire gets the smallest
  // pairing-safe shape we have.
  // Pairing belt-and-suspenders: the kept tail may carry pre-broken
  // pairing in the input; the request must never propagate it.
  return repairToolPairing(merged).messages;
}

/// The compact user-role carrier for one coalesced unit.
UserMessage _carrierOf(List<Message> unit) {
  final names = <String>[
    for (final message in unit)
      if (message is AssistantMessage)
        for (final call in message.content.whereType<ToolCall>()) call.name,
  ];
  final label = names.isEmpty
      ? '${unit.length} earlier message(s)'
      : 'tool turn(s) ${names.join(', ')}';
  return UserMessage.text(
    '[coalesced $label — ${unit.length} message(s) merged to fit the '
    'provider message cap; the full history stays in the session file]',
  );
}

String _carrierTextOf(UserMessage carrier) => carrier.content as String;
