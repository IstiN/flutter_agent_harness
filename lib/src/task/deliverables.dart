/// The durable subagent deliverable path (issue #1829): deliverable
/// capture, the redacting artifact writer, and the deliverable envelope.
///
/// A child report can be lost twice: generation-side output truncation
/// discards the `reply` payload, and delivery-side capping reduces a
/// successful payload to a head fragment. This module makes the
/// child-to-parent deliverable path size-safe:
///
/// - **Core flow A** — a successful over-cap `reply` / same-session
///   `agent_message` body is redacted, persisted to the child's existing
///   `AgentOutputStore`, and delivered as a bounded envelope (head excerpt
///   + `agent://` pointer + explicit completeness status) instead of the
///   bare head fragment.
/// - **Core flow B** — an output-truncated deliverable call is NEVER
///   executed (the fail-closed boundary in the agent loop is unchanged);
///   its salvage-parsed text is captured as a `partial` artifact and the
///   pointer rides the child completion/task result out of band.
/// - **Core flow C** — the chunk contract ([deliverableChunkContract])
///   published through the tool descriptions and child system prompt:
///   ordered `agent_message` parts + a final short `reply` manifest, with
///   the harness tracking observed parts and ruling on manifest
///   completeness (a child-authored "complete" label is not authoritative).
///
/// Invariants: deliverable TEXT only (never executable tool arguments —
/// I1); redaction runs before persistence (I3); `complete` / `partial` /
/// `artifact-unavailable` stay distinct (I4); the stored artifact is
/// exactly the redacted text — no repair (I5); same-session pointers only
/// (I6/E11).
library;

import '../types.dart' show ToolCall;
import 'output_manager.dart';
import 'subagent_manager.dart';

// The public named parameter maps to a private field; an initializing formal
// would make the parameter name private and unusable outside this library.
// ignore_for_file: prefer_initializing_formals

/// Tool names whose text payload the durable deliverable path captures.
/// The allowlist is the I1 boundary: no other tool's arguments are ever
/// inspected, persisted, or delivered by this path.
const Set<String> deliverableToolNames = {'reply', 'agent_message'};

/// What a recorded deliverable is: a stored artifact (over-cap body or
/// salvaged partial text), an observed report chunk, or a final-manifest
/// verdict.
enum DeliverableRecordKind { artifact, chunk, manifest }

/// One recorded deliverable event on a child's handle (issue #1829).
/// Rendered onto the parent's task result so the recipient sees explicit
/// completeness and resolvable pointers.
final class DeliverableRecord {
  DeliverableRecord.artifact({
    required this.childId,
    required this.outputId,
    required this.status,
    this.reportId,
    required this.chars,
  }) : kind = DeliverableRecordKind.artifact,
       partIndex = null,
       partCount = null,
       missingParts = const [],
       verdictNote = '',
       manifestVerdict = null;

  /// An observed report chunk (delivered directly or via artifact).
  DeliverableRecord.chunk({
    required this.childId,
    required this.reportId,
    required this.partIndex,
    this.outputId,
    required this.chars,
  }) : kind = DeliverableRecordKind.chunk,
       status = null,
       partCount = null,
       missingParts = const [],
       verdictNote = '',
       manifestVerdict = null;

  /// The verdict on a final report manifest: [manifestVerdict] is the
  /// HARNESS's ruling, never the child's label.
  DeliverableRecord.manifest({
    required this.childId,
    required this.reportId,
    required this.partCount,
    required bool complete,
    this.missingParts = const [],
    this.verdictNote = '',
    required this.chars,
  }) : kind = DeliverableRecordKind.manifest,
       status = null,
       outputId = null,
       partIndex = null,
       manifestVerdict = complete;

  final DeliverableRecordKind kind;

  /// The child that produced the deliverable.
  final String childId;

  /// Artifact completeness; null for chunk/manifest records.
  final AgentArtifactStatus? status;

  /// The `agent://` output id (artifacts, and oversize chunks). Null when
  /// the content was delivered directly with no artifact.
  final String? outputId;

  /// Child-selected report id, when the chunk/manifest protocol is in use.
  final String? reportId;

  /// Chunk part index (chunk records).
  final int? partIndex;

  /// Declared total part count (manifest records).
  final int? partCount;

  /// Parts of the manifest that were never observed (manifest records).
  final List<int> missingParts;

  /// Why a manifest was ruled incomplete, when not obvious from
  /// [missingParts] (duplicates, out-of-order arrivals, no declared count).
  final String verdictNote;

  /// The harness's completeness ruling for manifest records.
  final bool? manifestVerdict;

  /// Character count of the redacted artifact text (artifacts) or the raw
  /// chunk/manifest body.
  final int chars;

  /// Whether a manifest record ruled the report complete (all declared
  /// parts observed, none duplicated, none out of order).
  bool get manifestComplete => manifestVerdict ?? false;

  /// The resolvable pointer, or null for direct deliveries.
  String? get pointer => outputId == null ? null : 'agent://$outputId';

  /// One parent-visible line.
  String render() => switch (kind) {
    DeliverableRecordKind.artifact =>
      'deliverable ${status!.name}${reportId == null ? '' : ' (report $reportId)'}: '
          'agent://$outputId ($chars chars)',
    DeliverableRecordKind.chunk =>
      'report ${reportId!} part ${partIndex!}: '
          '${outputId == null ? 'delivered directly' : 'agent://$outputId'} '
          '($chars chars)',
    DeliverableRecordKind.manifest =>
      'report ${reportId!} manifest: '
          '${manifestComplete ? 'complete ($partCount parts)' : 'INCOMPLETE${verdictNote.isEmpty ? '' : ' — $verdictNote'}${missingParts.isEmpty ? '' : '; missing parts $missingParts'}'}',
  };
}

/// The harness-observed state of one child report's chunk set: arrival
/// order, duplicates, and which declared parts never showed up. Drives the
/// manifest verdict (Core flow C, E10): a child-authored "complete" label
/// cannot hide duplicate, missing, or out-of-order parts.
final class _ChunkLedger {
  final parts = <int>{};
  var duplicates = 0;
  var outOfOrder = 0;
  var nextExpected = 0;

  void observe(int partIndex) {
    if (!parts.add(partIndex)) {
      duplicates++;
      return;
    }
    if (partIndex != nextExpected) outOfOrder++;
    nextExpected = partIndex + 1;
  }

  /// Parts of `0..count-1` never observed.
  List<int> missingOf(int count) => [
    for (var i = 0; i < count; i++)
      if (!parts.contains(i)) i,
  ];
}

/// The child-side chunk contract published through the `reply` /
/// `agent_message` tool descriptions and the child system prompt (Core
/// flow C, AC5). [budget] is the live per-message character cap.
String deliverableChunkContract(int budget) =>
    'REPORT SIZE CONTRACT — the '
    'per-message delivery budget for report text is $budget characters. '
    'Reports above the budget are NOT lost (the harness stores them and '
    'delivers an excerpt plus an agent:// artifact pointer), but do not '
    'rely on that: split a long report body into ordered agent_message '
    'parts to the parent, each well below the budget, carrying a '
    'report_id, a 0-based part_index, and more=true on every part except '
    'the last (more=false). Never repeat earlier parts. Do NOT send one '
    'near-the-output-limit response to probe the limit — a truncated tool '
    'call fails unexecuted and only salvageable text is recovered. After '
    'the last part, send a short final reply whose message names the '
    'report_id and sets report_parts to the total part count — a manifest '
    'pointing at the already delivered parts, not a second copy of the '
    'report. Missing, duplicated, or out-of-order parts make the manifest '
    'incomplete; the parent will not reconstruct missing text.';

/// Harness-owned capture + redacting artifact writer + envelope builder
/// for one session (issue #1829). Bound to the session's existing
/// [AgentOutputStore] and [SubagentManager] (the `maxReplyChars` budget);
/// wired by the task executor into the child tool surface and the agent
/// loop's truncated-call hook.
final class DeliverableCapture {
  /// Creates a capture. [redact] is the pre-persistence gate (I3) — the
  /// same redaction pipeline tool results pass; null means the host runs
  /// no redactor (identity, matching unredacted tool-result delivery).
  DeliverableCapture({
    required this.store,
    required this.manager,
    String Function(String text)? redact,
  }) : _redact = redact;

  /// The session output store backing `agent://` resolution.
  final AgentOutputStore store;

  /// The retained-subagent manager owning the budget and the handles the
  /// records/pointers attach to.
  final SubagentManager manager;

  final String Function(String text)? _redact;

  /// The delivery budget (pointer and status overhead count toward it).
  int get cap => manager.maxReplyChars;

  /// Per-child, per-report chunk ledgers (Core flow C bookkeeping).
  final _ledgers = <String, Map<String, _ChunkLedger>>{};

  /// Why a deliverable could not be stored (E5) — surfaced explicitly, no
  /// raw bytes and no false pointer ride with it.
  String? unavailableReason;

  /// Redacts [text] through the wired pipeline (I3: mandatory
  /// pre-persistence gate).
  String _redactOrThrow(String text) => _redact == null ? text : _redact(text);

  /// Records an artifact: content is ALREADY redacted. When
  /// [checkEnvelopeFit] is true, throws [StateError] BEFORE anything is
  /// written when the cap cannot hold the envelope (AC8). Store failures
  /// propagate — the caller degrades, never a raw fallback.
  DeliverableRecord _persist({
    required String childId,
    required String redacted,
    required AgentArtifactStatus status,
    String? reportId,
    String idBase = 'report',
    bool checkEnvelopeFit = true,
  }) {
    final id = store.allocateId('$childId-$idBase');
    if (checkEnvelopeFit) {
      final overhead = _statusLine(status, id, redacted.length).length + 2;
      if (overhead >= cap) {
        throw StateError(
          'maxReplyChars ($cap) cannot hold a deliverable envelope '
          '(overhead $overhead) — raise the cap; refusing to emit a '
          'malformed pointer',
        );
      }
    }
    store.put(id, redacted);
    store.recordArtifact(
      id,
      AgentArtifactMeta(
        status: status,
        childId: childId,
        chars: redacted.length,
        reportId: reportId,
      ),
    );
    return DeliverableRecord.artifact(
      childId: childId,
      outputId: id,
      status: status,
      reportId: reportId,
      chars: redacted.length,
    );
  }

  /// The envelope status line for a stored deliverable (deterministic, so
  /// the fit check can run BEFORE anything is persisted).
  String _statusLine(AgentArtifactStatus status, String id, int chars) =>
      switch (status) {
        AgentArtifactStatus.complete =>
          '[deliverable complete: agent://$id ($chars chars)]',
        AgentArtifactStatus.partial =>
          '[deliverable PARTIAL — salvaged from an output-truncated call: '
              'agent://$id ($chars chars)]',
      };

  /// Core flow A for the `reply` channel: when [body] fits the budget,
  /// returns null (direct delivery, byte-identical, no artifact — AC1);
  /// otherwise stores the full redacted body and returns the envelope
  /// record. [reportId]/[reportParts] carry the final chunk manifest when
  /// the child uses the chunk protocol; the manifest verdict is recorded
  /// either way (E10).
  ///
  /// Throws [StateError] when the cap cannot hold a valid envelope — an
  /// explicit size/configuration error raised BEFORE anything is
  /// persisted, never a malformed pointer (AC8).
  DeliverableRecord? deliverReply(
    String childId,
    String body, {
    String? reportId,
    int? reportParts,
  }) {
    _recordManifest(
      childId,
      body,
      reportId: reportId,
      reportParts: reportParts,
    );
    if (body.length <= cap) return null;
    final redacted = _redactOrThrow(body);
    final record = _persist(
      childId: childId,
      redacted: redacted,
      status: AgentArtifactStatus.complete,
      reportId: reportId,
    );
    manager[childId]?.deliverables.add(record);
    return record;
  }

  /// Core flow A + chunk observation for the `agent_message` channel.
  /// Returns null when [target] is NOT a same-session recipient (A2A
  /// `name@machine`, cross-instance mailboxes, hub-only ids) — those keep
  /// the existing bare capping because they cannot resolve a same-session
  /// `agent://` pointer (E11). Returns null for in-budget bodies too
  /// (direct delivery, after ledger observation).
  DeliverableRecord? deliverAgentMessage({
    required String childId,
    required String target,
    required String body,
    String? reportId,
    int? partIndex,
  }) {
    if (!_isSameSession(target)) return null;
    if (reportId != null && partIndex != null) {
      _observeChunk(childId, reportId, partIndex);
      if (body.length <= cap) {
        final record = DeliverableRecord.chunk(
          childId: childId,
          reportId: reportId,
          partIndex: partIndex,
          chars: body.length,
        );
        manager[childId]?.deliverables.add(record);
        return record;
      }
    }
    if (body.length <= cap) return null;
    final redacted = _redactOrThrow(body);
    final record = _persist(
      childId: childId,
      redacted: redacted,
      status: AgentArtifactStatus.complete,
      reportId: reportId,
      idBase: 'chunk',
    );
    manager[childId]?.deliverables.add(record);
    return record;
  }

  /// Core flow B: the agent loop's truncated-call hook. Fails nothing,
  /// executes nothing (I2) — captures salvage-parsed deliverable TEXT as a
  /// partial artifact when the call is a deliverable and its `message`
  /// field holds usable text (E2: empty/absent/malformed fields create no
  /// artifact). The failure itself always stands.
  void captureSalvaged(String childId, ToolCall call) {
    manager[childId]?.hadTruncatedDeliverable = true;
    if (!deliverableToolNames.contains(call.name)) return;
    final text = call.arguments['message'];
    if (text is! String || text.trim().isEmpty) return;
    try {
      final redacted = _redactOrThrow(text);
      // No envelope fit check: a partial artifact is delivered via the
      // result's pointer line, not through a bounded envelope.
      final record = _persist(
        childId: childId,
        redacted: redacted,
        status: AgentArtifactStatus.partial,
        reportId: call.arguments['report_id'] is String
            ? call.arguments['report_id'] as String
            : null,
        checkEnvelopeFit: false,
      );
      manager[childId]?.deliverables.add(record);
    } on Object {
      // E5: redaction failed — no artifact, no invented completion, no
      // raw fallback. The original truncation error remains the only
      // recovery signal; the recorded [SubagentHandle
      // .hadTruncatedDeliverable] flag drives the tier-2 fallback.
    }
  }

  /// Whether [target] resolves INSIDE this session's shared store: a local
  /// child handle or the parent inbox. Cross-instance mailboxes (`/`),
  /// A2A addresses (`@`), and hub-only ids cannot resolve the pointer and
  /// keep the existing delivery (E11).
  bool _isSameSession(String target) =>
      !target.contains('@') &&
      !target.contains('/') &&
      (target == manager.selfId || manager[target] != null);

  void _observeChunk(String childId, String reportId, int partIndex) {
    _ledgers.putIfAbsent(childId, () => {})[reportId] ??= _ChunkLedger();
    _ledgers[childId]![reportId]!.observe(partIndex);
  }

  /// Validates the final chunk manifest (Core flow C step 3, E10): the
  /// verdict is the harness's — every declared part observed, none
  /// duplicated, none out of order — never the child's label. Recorded
  /// only when the child actually declares a manifest (reportId present).
  void _recordManifest(
    String childId,
    String body, {
    required String? reportId,
    required int? reportParts,
  }) {
    if (reportId == null) return;
    final ledger = _ledgers[childId]?[reportId];
    if (ledger == null || reportParts == null) {
      manager[childId]?.deliverables.add(
        DeliverableRecord.manifest(
          childId: childId,
          reportId: reportId,
          partCount: reportParts ?? ledger?.parts.length ?? 0,
          complete: false,
          missingParts: reportParts == null
              ? const []
              : ledger?.missingOf(reportParts) ?? const [],
          verdictNote: reportParts == null
              ? 'manifest does not declare the part count'
              : 'no parts were observed for this report id',
          chars: body.length,
        ),
      );
      return;
    }
    final missing = ledger.missingOf(reportParts);
    final note = StringBuffer();
    if (ledger.duplicates > 0) {
      note.write('${ledger.duplicates} duplicate part(s); ');
    }
    if (ledger.outOfOrder > 0) note.write('parts arrived out of order; ');
    manager[childId]?.deliverables.add(
      DeliverableRecord.manifest(
        childId: childId,
        reportId: reportId,
        partCount: reportParts,
        complete:
            missing.isEmpty && ledger.duplicates == 0 && ledger.outOfOrder == 0,
        missingParts: missing,
        verdictNote: note.toString().trim(),
        chars: body.length,
      ),
    );
  }

  /// The parent-visible envelope for a stored deliverable (Core flow A):
  /// bounded redacted head excerpt + resolvable pointer + explicit
  /// completeness, sized to fit [cap]. The fit was already verified before
  /// persistence; this formats it.
  String envelopeText(DeliverableRecord record, String body) {
    final statusLine = _statusLine(
      record.status!,
      record.outputId!,
      record.chars,
    );
    final excerptEnd = _safeExcerptEnd(body, cap - statusLine.length - 2);
    final excerpt = body.substring(0, excerptEnd);
    return '$excerpt…\n$statusLine';
  }

  /// The largest excerpt end ≤ [max] that does not split a surrogate pair.
  static int _safeExcerptEnd(String text, int max) {
    var end = max < text.length ? max : text.length;
    if (end > 0 &&
        end < text.length &&
        text.codeUnitAt(end - 1) >= 0xD800 &&
        text.codeUnitAt(end - 1) <= 0xDBFF) {
      end--;
    }
    return end;
  }
}
