// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// The working-set STORE (issue #2423, C1): how the `working_set` tool
/// reaches the agent's OWN session, and how a request build reads the
/// newest snapshot back — with no host capability in the way.
///
/// The harness keeps the `Agent` and its session file apart: hosts persist
/// in-memory messages through their own seams (the CLI persist window, the
/// task executor's per-child flush), so a tool constructed by the host
/// wiring can only ever see the HOST's session — the gh-210 defect (a task
/// child calling `recite_goal` would have landed in the parent's file).
/// This library closes it with two pieces:
///
/// - [WorkingSetStore] — the write/read contract over one session
///   ([SessionWorkingSetStore] is the append-only `custom`-record
///   implementation with redaction on write).
/// - A zone-scoped binding ([runWithWorkingSetStore] /
///   [activeWorkingSetStore]) — the same mechanism as the subagent scope
///   (`task/subagent_scope.dart`): whoever owns the agent's session runs
///   the agent inside the binding, and the tool resolves the store AT CALL
///   TIME. `Agent._runWithLifecycle` publishes `Agent.workingSetStore`, so
///   a task child (its own session) and the main agent (the host's
///   session) both reach their own file; the constructed store
///   (`AgentCoreServices.workingSet`) is the fallback for a host that
///   binds the session outside the agent.
library;

import 'dart:async';

import '../redact/redaction_pipeline.dart' show RedactionPipeline;
import '../session/session_tree.dart' show Session;
import 'working_set_snapshot.dart';

/// What one working-set write produced — the tool derives its result text
/// from it and the host gets the observability callback.
final class WorkingSetSaveResult {
  /// Creates a [WorkingSetSaveResult].
  const WorkingSetSaveResult({
    required this.snapshot,
    this.redactions = 0,
    this.overCap = false,
  });

  /// The stored snapshot (the redacted, trimmed text). On an [overCap]
  /// refusal it is the REFUSED text — nothing was written.
  final WorkingSetSnapshot snapshot;

  /// How many redaction matches the session redactor applied before the
  /// write (the tool result reports it — E14).
  final int redactions;

  /// `true` when the text exceeded [workingSetMaxChars] (after redaction)
  /// and was REFUSED: no record was appended, the previous snapshot stays.
  final bool overCap;

  /// The CLEAR event was stored (an empty text).
  bool get cleared => snapshot.isClear;
}

/// The working-set contract over one agent's session.
abstract interface class WorkingSetStore {
  /// Appends one snapshot (latest wins) and reports what was stored.
  /// Failures are THROWN — the tool converts them into the agent-visible
  /// "not saved" result (the `closeObligation` contract).
  Future<WorkingSetSaveResult> save(String text);

  /// The newest snapshot of the session, or `null` when none exists.
  Future<WorkingSetSnapshot?> load();
}

/// The append-only session store: `Session.appendCustomEntry` with the
/// `working_set` record kind (no record is ever rewritten) and the
/// session's own complete reader (resident view, then the windowed-scan
/// fallback) for [load].
final class SessionWorkingSetStore implements WorkingSetStore {
  /// Creates a [SessionWorkingSetStore] over the session [session]
  /// resolves at call time (the host's current session — it can change
  /// under a live CLI, e.g. `/resume`).
  SessionWorkingSetStore({
    required this.session,
    Future<Session?> Function()? openSession,
    this.redaction,
    this.onSaved,
  }) {
    _openSession = openSession;
  }

  /// Resolves the agent's own session for a WRITE (a task executor may
  /// create the child's session here). May throw — the failure becomes the
  /// agent-visible "not saved" result.
  final Future<Session> Function() session;

  /// The READ resolver: the session as it exists right now (`null` = none
  /// yet). A task executor passes its already-created child session so a
  /// request build never creates one; by default reads use [session].
  Future<Session?> Function()? _openSession;

  /// The session redactor (the host's `redaction:` pipeline): every text
  /// passes it BEFORE the record is written, so the session JSONL never
  /// holds a secret the run already masks elsewhere (E14).
  final RedactionPipeline? redaction;

  /// Observability: called after a stored write (never on a refusal) —
  /// the hosts print the dim line / emit the HEP frame (sizes and numbers
  /// only, never the text).
  final void Function(WorkingSetSaveResult result)? onSaved;

  @override
  Future<WorkingSetSaveResult> save(String text) async {
    var redactions = 0;
    var safe = text;
    final pipeline = redaction;
    if (pipeline != null) {
      final before = pipeline.stats.total;
      safe = pipeline.redact(text);
      redactions = pipeline.stats.total - before;
    }
    final snapshot = WorkingSetSnapshot(text: safe, updatedAt: DateTime.now());
    // Belt over the tool's own check: a text the redactor pushed over the
    // cap is refused here too — never clipped, never written.
    if (safe.length > workingSetMaxChars) {
      return WorkingSetSaveResult(
        snapshot: snapshot,
        redactions: redactions,
        overCap: true,
      );
    }
    await (await session()).appendCustomEntry(
      customType: workingSetRecordType,
      data: snapshot.toPayload(),
    );
    final result = WorkingSetSaveResult(
      snapshot: snapshot,
      redactions: redactions,
    );
    onSaved?.call(result);
    return result;
  }

  @override
  Future<WorkingSetSnapshot?> load() async {
    // Never throws: a session that cannot be resolved right now (no
    // session open, a child whose file does not exist yet) simply has no
    // snapshot — the request build must not fail over the block.
    final Session? resolved;
    try {
      resolved = await (_openSession ?? session)();
    } on Object {
      return null;
    }
    return resolved?.workingSetSnapshot();
  }
}

const Symbol _workingSetStoreZoneKey = #fahWorkingSetStore;

/// The working-set store of the agent whose run encloses the caller, or
/// `null` outside a bound run (host code, an unbound agent).
WorkingSetStore? activeWorkingSetStore() =>
    Zone.current[_workingSetStoreZoneKey] as WorkingSetStore?;

/// Runs [body] with [store] published as the enclosing agent's working-set
/// store. Nested scopes shadow outer ones; the value is visible to every
/// callback executed within [body]'s async chain (tool executions
/// included).
R runWithWorkingSetStore<R>(WorkingSetStore store, R Function() body) =>
    runZoned(body, zoneValues: {_workingSetStoreZoneKey: store});
