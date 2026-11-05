// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Compaction parity for the extension SW host (gh-2059): the extension
/// consumes exactly the shared SDK wiring the CLI and the Flutter app
/// consume — `resolveCompactionHostWiring` (gh-1077) as the ONLY compaction
/// config source, the shared [AutoCompactorFactory] for the pass loop —
/// and adds only the host-specific seams around it.
///
/// This file is the VM-testable unit behind the web-only `agent_host.dart`
/// (package:web imports keep the host itself off the VM). Everything the
/// ACs pin lives here:
///
/// - **wiring** — [resolveExtensionCompactionWiring] joins the parity test
///   (`flutter_app/test/compaction_host_wiring_test.dart`, AC10): window
///   from the shared resolution (catalog/fallback + owner cap), thresholds
///   scaled by the shared `forWindow` rule of the conversation window, the
///   pinned retry ladder, `enabled` default. No local constants.
/// - **relief** — [ExtensionCompactionRunner.relieveOverWindow] is the
///   `overWindowRelief` the host wires into the Agent (issue #387 shape,
///   #1085 cancel parity via the linked run token).
/// - **manual /compact** — [ExtensionCompactionRunner.manualCompact]: the
///   CLI's unconditional manual pass (force), with the before/after
///   receipt notice and the "compaction interrupted" contract.
/// - **under-window guarantee + re-fire ladder** (gh-1425 / arch 6) —
///   after any path the live context is re-measured; still at/over the
///   effective window → ONE more pass; ladder exhausted → a VISIBLE
///   failure notice, transcript intact.
/// - **visibility** (gh-1077 AC2 / AC4 / AC11) — every pass emits ≥1 SW
///   log line through the injected [ExtensionCompactionRunner.log] seam
///   (the host binds `providerDebug`: print + panel relay, the
///   `[fah][sw]` channel), and every failure/exhaustion emits a panel
///   system notice through [ExtensionCompactionRunner.notice].
/// - **slash dispatch** — [parseSlashInput]: `/compact` routes to the
///   manual pass and never enters the transcript; an unknown bare
///   `/token` is refused with the CLI's wording; multi-word/path-like
///   input stays an ordinary message (CLI `_handlePathLikeInput` parity).
///
/// Pure Dart: no `dart:io`, no `package:web`, no chrome imports.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/agent.dart';
import 'package:flutter_agent_harness/src/agent/auto_compactor.dart';
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/compaction/compaction.dart';
import 'package:flutter_agent_harness/src/compaction/host_wiring.dart';
import 'package:flutter_agent_harness/src/compaction/token_estimation.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/session/session_tree.dart';
import 'package:flutter_agent_harness/src/types.dart';

/// The in-chat/SW-log failure notice lead (gh-1077 AC2 shape). The
/// extension has no Task-models settings surface, so the fix hint points
/// at the provider connection instead of the app's Quick-model slot.
/// The IT suite asserts this string; change both together.
const String extCompactionFailureNoticeLead =
    'Context compaction failed — nothing was summarized and no history '
    'was lost. Check the provider connection (key/quota/endpoint) in '
    'Settings, or run /compact again once it works.';

/// The full failure notice: the lead plus the underlying error.
String extCompactionFailureNotice(Object error) =>
    '$extCompactionFailureNoticeLead\n$error';

/// The ladder-exhausted notice (arch 6): the transcript is still at/over
/// the effective window after the re-fire — the next request may be
/// refused, and the user learns why INSTEAD of a silent stuck loop.
const String extCompactionExhaustedNotice =
    'Context is still over the model window after compaction — the next '
    'request may be refused. The transcript is intact; start a fresh '
    'session if the endpoint keeps refusing.';

/// The extension's fixed request overhead (gh-1077 parity with the app's
/// `_systemOverheadTokens`): the rendered system prompt's token estimate.
/// The tool schemas ride the measurement basis itself
/// ([estimateRequestTokens] adds them when unanchored), so — same as the
/// app — only the system prompt is subtracted here.
int extensionSystemOverheadTokens(String systemPrompt) =>
    estimateTokens(UserMessage.text(systemPrompt));

/// Resolves the extension host's compaction wiring (gh-2059 AC10): the
/// SAME shared semantics the CLI ([resolveCliCompactionWiring]) and the
/// app compute through, with the extension's inputs — no smol role is
/// configurable on this host today, so `smolModel` is always `null` (the
/// main stream summarizes, single-attempt fallback per the shared
/// resolution). Exposed as a named function so the three-host parity test
/// compares the extension's REAL resolution, not a copy of it.
CompactionHostWiring resolveExtensionCompactionWiring({
  required Model mainModel,
  required int systemOverheadTokens,
  int? contextWindowCap,
  CompactionSettings? settingsOverride,
}) => resolveCompactionHostWiring(
  mainModel: mainModel,
  smolModel: null,
  contextWindowCap: contextWindowCap,
  settingsOverride: settingsOverride,
  systemOverheadTokens: systemOverheadTokens,
);

/// The slash-input decision for the panel composer (AC2 + unknown-slash
/// parity with the CLI dispatcher):
///
/// - `/compact` (+ optional rest, both ignored beyond the match) →
///   [SlashCompact] — never a transcript message.
/// - a BARE unknown `/token` (no spaces — multi-word input starting with
///   a path is a MESSAGE, CLI `_handlePathLikeInput` parity) →
///   [SlashUnknown] with the token.
/// - everything else → `null` (ordinary user input).
sealed class SlashDecision {
  const SlashDecision();
}

/// `/compact`: run the manual compaction pass.
final class SlashCompact extends SlashDecision {
  const SlashCompact();
}

/// A bare unknown slash token: refused with the CLI's wording, never a
/// transcript message. Value equality on [token] (a decision result, not
/// an identity).
final class SlashUnknown extends SlashDecision {
  const SlashUnknown(this.token);

  final String token;

  @override
  bool operator ==(Object other) =>
      other is SlashUnknown && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

SlashDecision? parseSlashInput(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('/') || trimmed.length < 2) return null;
  final split = RegExp(r'\s').allMatches(trimmed).toList();
  final token = split.isEmpty
      ? trimmed
      : trimmed.substring(0, split.first.start);
  if (token == '/compact') return const SlashCompact();
  // Multi-word input (a message that happens to start with `/…`) and
  // path-like tokens (`/a/b` — a second `/` beyond the command position)
  // are ordinary input — only a bare unknown command is refused.
  if (split.isNotEmpty) return null;
  if (token.indexOf('/', 1) >= 0) return null;
  return SlashUnknown(token);
}

/// The host-side routing decision for one panel input (gh-2059 machine
/// review B2/I1): pure over (text, running, compacting) so the web-only
/// host glue stays mechanical and the busy matrix is VM-testable.
sealed class UserRoute {
  const UserRoute();
}

/// Ordinary input, host idle → run the turn.
final class RouteRunTurn extends UserRoute {
  const RouteRunTurn();
}

/// Ordinary input while a turn already streams → steer the live turn
/// (never a second concurrent stream).
final class RouteSteer extends UserRoute {
  const RouteSteer();
}

/// Input refused because the host is busy. A manual /compact MUTATES the
/// transcript: no concurrent turn may start against it (B2), and a
/// second /compact gets this busy error instead of an unhandled
/// StateError from the single-flight guard (I1).
final class RouteBusy extends UserRoute {
  const RouteBusy(this.reason);

  final String reason;

  @override
  bool operator ==(Object other) =>
      other is RouteBusy && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}

/// `/compact`, host idle → run the manual pass.
final class RouteCompact extends UserRoute {
  const RouteCompact();
}

/// A bare unknown `/token` → refused with the CLI wording.
final class RouteUnknown extends UserRoute {
  const RouteUnknown(this.token);

  final String token;

  @override
  bool operator ==(Object other) =>
      other is RouteUnknown && other.token == token;

  @override
  int get hashCode => token.hashCode;
}

UserRoute routeUserInput({
  required String text,
  required bool running,
  required bool compacting,
}) {
  switch (parseSlashInput(text)) {
    case SlashCompact():
      // One compactor at a time: busy while ANY host work runs — a
      // concurrent turn racing the pass mutation is the B2 race, a
      // second concurrent /compact is the I1 StateError.
      if (running || compacting) {
        return const RouteBusy(
          'busy: /compact needs an idle session — wait for the current '
          'work to finish',
        );
      }
      return const RouteCompact();
    case SlashUnknown(:final token):
      return RouteUnknown(token);
    case null:
      break;
  }
  // Ordinary panel text mid-compact is refused (B2): the pass mutates
  // the very transcript a concurrent turn would read.
  if (compacting) {
    return const RouteBusy(
      'busy: a manual /compact is running — it will report when done',
    );
  }
  if (running) return const RouteSteer();
  return const RouteRunTurn();
}

/// The durable compaction receipts (gh-2059 machine review S2): a
/// bounded, session-scoped list of notice lines the host persists next to
/// the session and replays to every attaching panel — a notice emitted
/// while no panel was attached, or before an SW restart, still reaches
/// the UI. Pure and VM-testable; the host binds the storage env.
final class CompactionNoticeBacklog {
  static const cap = 20;

  /// The storage path (host root — session-adjacent, not per-session:
  /// receipts describe the agent conversation the SW owns).
  static const storagePath = '/fa-compaction-notices.json';

  CompactionNoticeBacklog([List<String>? lines])
    : _lines = List.of(lines ?? const []);

  final List<String> _lines;

  /// Oldest first, capped at [cap] (the newest receipts survive).
  List<String> get lines => List.unmodifiable(_lines);

  void add(String text) {
    _lines.add(text);
    if (_lines.length > cap) {
      _lines.removeRange(0, _lines.length - cap);
    }
  }

  void clear() => _lines.clear();

  String encode() => jsonEncode(_lines);

  /// Best-effort decode: a corrupt/truncated payload yields an empty
  /// backlog (receipts are diagnostics — never a boot blocker).
  factory CompactionNoticeBacklog.decode(Object? raw) {
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return CompactionNoticeBacklog(decoded.whereType<String>().toList());
        }
      } on FormatException {
        // fall through
      }
    }
    return CompactionNoticeBacklog();
  }
}

/// One compaction path's outcome: the honest numbers a host (or a test)
/// asserts on.
final class CompactionRunResult {
  const CompactionRunResult({
    required this.before,
    required this.after,
    required this.passes,
    this.failure,
    this.exhausted = false,
  });

  /// Estimated request tokens before the path started.
  final int before;

  /// Estimated request tokens after the path finished.
  final int after;

  /// Summarizer/trim passes that actually ran (across the whole ladder).
  final int passes;

  /// The failure that ended the path (both summarizers failed, or the
  /// factory threw). `null` = no pass failure.
  final Object? failure;

  /// The re-fire ladder ran out with the context still at/over the
  /// effective window (arch 6's visible terminal state).
  final bool exhausted;

  bool get freed => after < before;

  /// The AC3 under-window invariant against [wiring]: the live request
  /// estimate is under the conversation window minus the reserve (the
  /// strictest bound the compactor can honestly guarantee — it implies
  /// the raw `window - reserveTokens` form too).
  bool underWindow(CompactionHostWiring wiring) =>
      after < wiring.conversationWindow - wiring.settings.reserveTokens;
}

/// The manual `/compact` outcome (AC2): `ran` distinguishes a real pass
/// from "nothing to compact"; `passes` is the exact delta the ladder
/// added (machine-review B1 — the receipt count); `exhausted` is the AC5
/// terminal state (the ladder ran out with the context still over the
/// trigger); `underWindow` is the AC3 invariant for the settled estimate.
final class ManualCompactionOutcome {
  const ManualCompactionOutcome({
    required this.ran,
    required this.before,
    required this.after,
    this.passes = 0,
    this.failure,
    this.exhausted = false,
    this.underWindow = false,
  });

  final bool ran;
  final int passes;
  final int before;
  final int after;
  final Object? failure;
  final bool exhausted;
  final bool underWindow;
}

/// The extension host's compaction paths, over the shared wiring. One
/// instance per booted host; the host injects the two visibility seams
/// (`log` → the `[fah][sw]` SW console + panel relay; `notice` → the
/// panel system-notice event).
final class ExtensionCompactionRunner {
  final Session session;
  final Agent agent;

  /// The owner cap (`agent.contextWindowCap` analogue) — mutable: a live
  /// reconfigure swaps it alongside the model.
  int? contextWindowCap;

  /// The visibility seams (gh-2059 arch 5): every pass/retry/outcome
  /// line rides [log] (the host binds `providerDebug` — SW console +
  /// panel relay), failures and receipts ride [notice] (the panel
  /// system-notice event).
  final void Function(String line) log;
  final void Function(String text) notice;

  ExtensionCompactionRunner({
    required this.session,
    required this.agent,
    this.contextWindowCap,
    required this.log,
    required this.notice,
  });

  /// The AC1 relief counter (the app's `overWindowReliefCountForTest`
  /// analogue).
  int reliefCount = 0;

  /// The shared wiring (gh-1077): window/thresholds/summarizer/retry/
  /// enabled, resolved fresh on every read — a reconfigure that swaps the
  /// model applies at the NEXT compaction, exactly like the app's getter.
  CompactionHostWiring get wiring => resolveExtensionCompactionWiring(
    mainModel: agent.state.model,
    systemOverheadTokens: extensionSystemOverheadTokens(
      agent.state.systemPrompt,
    ),
    contextWindowCap: contextWindowCap,
  );

  /// The live request-size estimate on the ONE basis the loop's
  /// over-window guard and the ctx meter enforce (transcript + system
  /// prompt/tool-schema overhead when unanchored).
  int get requestTokens => estimateRequestTokens(
    agent.state.messages,
    systemPrompt: agent.state.systemPrompt,
    tools: agent.state.tools,
  );

  /// The settle path (the host's `AgentSettledEvent` hook, app parity):
  /// gated by the shared [shouldCompact] on the wiring's conversation
  /// window, skipped when the whole transcript fits the kept region.
  Future<bool> compactIfDue() async {
    final w = wiring;
    if (!w.enabled) return false;
    final conversationWindow = w.conversationWindow;
    if (conversationWindow <= 0) return false;
    final transcriptTokens = requestTokens;
    if (!shouldCompact(transcriptTokens, conversationWindow, w.settings)) {
      return false;
    }
    // The whole transcript fits in the kept region: compaction could not
    // drop anything (app parity — a single oversized message surfaces as
    // a readable failure instead).
    if (transcriptTokens <= w.settings.keepRecentTokens) return false;
    final result = await _compact(force: false);
    return result.freed;
  }

  /// The loop's over-window relief (issue #387 shape): ONE synchronous
  /// compaction attempt for the guard's single retry. Returns the
  /// relieved transcript, or `null` when compaction freed nothing (the
  /// loop then surfaces its verbatim guard error — or, issue #1085, the
  /// aborted turn when [runToken] was cancelled mid-relief).
  Future<List<Message>?> relieveOverWindow(
    List<Message> overWindow, {
    CancelToken? runToken,
  }) async {
    reliefCount++;
    // AC8 (issue #1085): an already-aborted run gets NO compaction at all
    // — the relief returns null, the loop lands the aborted turn, and no
    // pass mutation ships. (A cancel that lands MID-pass is converted by
    // the shared AutoCompactor itself; the loop still surfaces aborted.)
    if (runToken?.isCancelled ?? false) {
      log(
        '[fah][sw] compaction: over-window relief skipped — run '
        'cancelled',
      );
      return null;
    }
    final before = estimateRequestTokens(
      overWindow,
      systemPrompt: agent.state.systemPrompt,
      tools: agent.state.tools,
    );
    log('[fah][sw] compaction: over-window relief start tokens=$before');
    await _compact(runToken: runToken);
    final after = requestTokens;
    if (after >= before) {
      log('[fah][sw] compaction: over-window relief no-op');
      return null;
    }
    log(
      '[fah][sw] compaction: over-window relief done tokens=$after '
      '(was $before)',
    );
    return agent.state.messages.toList();
  }

  /// The manual `/compact` (CLI parity: unconditional `force`, the user
  /// asked for it). Emits the AC2 receipt notice with before/after
  /// tokens — only for a pass that actually FREED tokens (a pass that
  /// grew the estimate is not a "compacted" receipt; the exhaustion
  /// notice, when it fired, is that path's receipt); a cancelled pass
  /// surfaces `CancelledException` AFTER the "compaction interrupted"
  /// notice (CLI `_runManualCompact` wording) — never as a failed-pass
  /// mutation report.
  Future<ManualCompactionOutcome> manualCompact({CancelToken? runToken}) async {
    if (agent.state.messages.isEmpty) {
      log('[fah][sw] compaction: manual /compact — nothing to compact');
      notice('nothing to compact — the transcript is empty');
      // Zero tokens are trivially under any positive window.
      return const ManualCompactionOutcome(
        ran: false,
        before: 0,
        after: 0,
        underWindow: true,
      );
    }
    final result = await _compact(force: true, runToken: runToken);
    if (runToken?.isCancelled ?? false) {
      notice('compaction interrupted');
      runToken?.throwIfCancelled();
    }
    if (result.failure != null) {
      return ManualCompactionOutcome(
        ran: result.passes > 0,
        passes: result.passes,
        before: result.before,
        after: result.after,
        failure: result.failure,
        exhausted: result.exhausted,
        underWindow: _underWindow(result.after),
      );
    }
    if (result.passes > 0 && result.after < result.before) {
      // The AC2 receipt, with the honest exact pass count (the ladder
      // delta, never the cumulative counter — machine-review B1).
      notice(
        'compacted: ${result.before} → ${result.after} tokens '
        '(${result.passes} pass${result.passes == 1 ? '' : 'es'})',
      );
    } else if (!result.exhausted) {
      // No freed tokens and no exhaustion receipt: say why instead of a
      // misleading receipt (machine-review digest: a pass can run and
      // still not shrink — the exhaustion notice covers the over-trigger
      // case).
      notice(
        'nothing to compact — every message is already summarized or the '
        'transcript is at its smallest',
      );
    }
    return ManualCompactionOutcome(
      ran: result.passes > 0,
      passes: result.passes,
      before: result.before,
      after: result.after,
      exhausted: result.exhausted,
      underWindow: _underWindow(result.after),
    );
  }

  /// The AC3 invariant for a live estimate: under the compaction trigger
  /// (`conversationWindow - reserveTokens`, the strictest honest bound).
  bool _underWindow(int tokens) {
    final w = wiring;
    return tokens < w.conversationWindow - w.settings.reserveTokens;
  }

  /// The shared path body: factory run + the re-fire ladder (arch 6 /
  /// AC5). The [AutoCompactorFactory] already multi-passes internally
  /// until under-window or exhausted; the ladder re-fires the WHOLE run
  /// once when the post-pass measurement is still at/over the compaction
  /// trigger (`conversationWindow - reserveTokens` — the gh-1425 basis:
  /// "under the trigger" is what keeps the next turn from re-firing),
  /// then declares exhaustion with a visible notice.
  Future<CompactionRunResult> _compact({
    bool force = false,
    CancelToken? runToken,
  }) async {
    final w = wiring;
    final trigger = w.conversationWindow - w.settings.reserveTokens;
    final hooks = _VisibleHooks(log: log, notice: notice, runToken: runToken);
    final before = requestTokens;
    var passes = 0;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        if (requestTokens < trigger) break;
        if (runToken?.isCancelled ?? false) break;
        log('[fah][sw] compaction: still over the trigger — re-firing once');
      }
      passes += await _runFactoryOnce(
        wiring: w,
        hooks: hooks,
        force: force || attempt > 0,
        runToken: runToken,
      );
      if (hooks.failure != null) break;
    }
    final after = requestTokens;
    // A user cancel is an ABORT, never a failed-pass report (issue #1085
    // parity): no exhaustion notice either — the loop/host surfaces the
    // abort.
    final cancelled = runToken?.isCancelled ?? false;
    var exhausted = false;
    if (!cancelled && hooks.failure == null && after >= trigger && passes > 0) {
      exhausted = true;
      log('[fah][sw] compaction: ladder exhausted tokens=$after');
      notice(extCompactionExhaustedNotice);
    }
    return CompactionRunResult(
      before: before,
      after: after,
      passes: passes,
      failure: hooks.failure,
      exhausted: exhausted,
    );
  }

  /// ONE factory run; returns only the passes THIS run added (the hooks
  /// counter is cumulative across the ladder — a machine-review B1 fix:
  /// adding the cumulative count per attempt inflated the receipt).
  Future<int> _runFactoryOnce({
    required CompactionHostWiring wiring,
    required _VisibleHooks hooks,
    required bool force,
    required CancelToken? runToken,
  }) async {
    final before = hooks.passes;
    try {
      await AutoCompactorFactory(
        session: session,
        state: agent.state,
        window: wiring.conversationWindow,
        settings: wiring.settings,
        sources: AutoCompactorSources(
          // The extension resolves no smol role today: the wiring says
          // `null` and the factory's documented fallback applies (the
          // main stream summarizes both slots, single attempt).
          smolStream: wiring.smolModel == null ? null : agent.streamFunction,
          smolModel: wiring.smolModel,
          mainStream: agent.streamFunction,
          mainModel: agent.state.model,
        ),
        hooks: hooks,
        runToken: runToken,
        force: force,
      ).run();
    } on Object catch (error) {
      // A throwing run is a compaction failure like any other — visible,
      // never silent (gh-1077 AC2). A user cancel rides the abort path.
      if (!(runToken?.isCancelled ?? false)) {
        hooks.onBothRolesFailed(error);
      }
    }
    return hooks.passes - before;
  }
}

/// The shared hooks impl (gh-2059 arch 5): every callback surfaces an SW
/// console line via `providerDebug` (print + panel relay), and a
/// both-roles failure additionally fires the panel system notice. Replaces
/// the deleted `_SilentHooks` — a pass can no longer run invisibly.
final class _VisibleHooks implements AutoCompactorHooks {
  _VisibleHooks({required this.log, required this.notice, this.runToken});

  final void Function(String line) log;
  final void Function(String text) notice;
  final CancelToken? runToken;

  int passes = 0;
  Object? failure;

  @override
  void onPass(AutoCompactorPass pass) {
    passes++;
    // AC11: this one line answers "did a pass run, what did it drop" —
    // before → after tokens, which engine ran, and the dropped/hidden/
    // summarized counts.
    log(
      '[fah][sw] compaction pass ${pass.pass}: '
      '${pass.tokensBefore} → ${pass.tokensAfter} tokens '
      'engine=${pass.fallback ?? 'none'} ok=${pass.ok} '
      'hidden=${pass.hiddenRecords} '
      'summarized=${pass.summarizedMessages} '
      'dropped=${pass.droppedMessages}'
      '${pass.ok ? '' : ' error=${pass.error}'}',
    );
  }

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {
    log(
      '[fah][sw] compaction retry $attempt/$maxAttempts in '
      '${backoff.inMilliseconds}ms: $error',
    );
  }

  @override
  void onDone(int passes, int tokens) {
    log('[fah][sw] compaction done passes=$passes freed=$tokens');
  }

  @override
  void onBothRolesFailed(Object lastError) {
    if (runToken?.isCancelled ?? false) {
      // A user abort mid-pass surfaces as aborted (issue #1085), never
      // as a failed-pass notice.
      return;
    }
    failure = lastError;
    log('[fah][sw] compaction failed: $lastError');
    notice(extCompactionFailureNotice(lastError));
  }

  @override
  void onDelta(String delta) {
    // High-frequency summarizer deltas: the panel renders the pass
    // receipt, not the stream. ponytail: intentionally silent.
  }

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {
    log(
      '[fah][sw] compaction attempt $attempt on $label '
      '(budget ${budget.inSeconds}s)',
    );
  }
}
