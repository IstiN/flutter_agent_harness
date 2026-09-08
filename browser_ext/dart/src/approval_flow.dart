// Pure-Dart approval-flow core for the extension service worker (issue:
// "busy forever" regression). The host (agent_host.dart) is web-only and
// untestable on the VM; this module carries the DECISION logic so it can
// be pinned by tests:
//
//   - pending prompts keyed `ap-N` with the 120s timeout backstop (deny
//     with a note) — unchanged wire events (`approval_request` /
//     `approval_resolved`);
//   - the panel's decide path, returning the target origin so the host
//     can seed the exfil-gate visited set (only on allow);
//   - the mid-run rescue: `resolveAll` completes every pending prompt at
//     once — the host calls it when the user flips the approval mode to
//     yolo/unattended while a turn is stalled on an unanswered prompt
//     (previously the busy guard dropped the mode change entirely and the
//     turn stalled 120s per gated tool call).
//
// Regression context: the panel chatted through a surface with no
// approval handler mounted; every gated call sat out the full timeout,
// got denied ("The user denied …"), the agent tried the next gated tool —
// the user saw a permanent "busy" badge, no output, and a yolo switch
// that "did nothing".
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/approval/approval.dart'
    show ApprovalMode;

import 'security/exfil_gate.dart' show originOf;

/// Wire-event sink (the host's `_sink`): one JSON-able map per event.
typedef ApprovalEventSink = void Function(Map<String, dynamic> event);

/// Outcome of a decide attempt: whether the id was pending, and the
/// parsed target origin (for the host to seed the exfil visited set on
/// allow — never on deny).
class DecisionOutcome {
  const DecisionOutcome({required this.found, this.origin});

  /// Whether the id named a pending approval.
  final bool found;

  /// `scheme://host[:port]` of `arguments['url']`, when the call had one.
  final String? origin;
}

/// Pending-approval bookkeeping for one host: create prompts, answer them
/// from the panel, time out the unanswered, and bulk-resolve on a mode
/// change. All wire shapes mirror the events agent_host emitted before
/// the extraction.
final class ApprovalFlow {
  ApprovalFlow({
    required ApprovalEventSink sink,
    this.timeout = const Duration(seconds: 120),
  }) : _sink = sink;

  /// How long an unanswered prompt pends before the conservative deny.
  /// The SW's only backstop when no connected client can answer.
  final Duration timeout;

  final ApprovalEventSink _sink;
  final _pending = <String, Completer<bool>>{};
  final _origins = <String, String>{};
  var _seq = 0;

  bool get hasPending => _pending.isNotEmpty;

  /// Opens a prompt and completes with the decision (false on timeout).
  Future<bool> request({
    required String toolName,
    required Map<String, dynamic> arguments,
    required String reason,
  }) {
    final id = 'ap-${++_seq}';
    final completer = Completer<bool>();
    _pending[id] = completer;
    final targetUrl = arguments['url'];
    if (targetUrl is String) {
      final origin = originOf(targetUrl);
      if (origin != null) _origins[id] = origin;
    }
    final summary = '$toolName ${_encode(arguments)}';
    _sink({
      'type': 'approval_request',
      'id': id,
      'summary': summary.length > 300
          ? '${summary.substring(0, 300)}…'
          : summary,
      // The panel dialog reads the tool name and raw args from here.
      'call': {'toolName': toolName, ...arguments},
      'reason': reason,
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false); // timeout → deny, noted
        _sink({
          'type': 'approval_resolved',
          'id': id,
          'allow': false,
          'note': 'timed out after ${timeout.inSeconds}s — denied',
        });
      }
    });
    return completer.future.whenComplete(() {
      timer.cancel();
      _pending.remove(id);
    });
  }

  /// The panel answered a banner. Unknown/already-resolved ids are a
  /// found=false no-op (late double-answers from a second client).
  DecisionOutcome decide(String id, bool allow) {
    final completer = _pending.remove(id);
    if (completer == null) return const DecisionOutcome(found: false);
    final origin = _origins.remove(id);
    if (!completer.isCompleted) completer.complete(allow);
    return DecisionOutcome(found: true, origin: allow ? origin : null);
  }

  /// Completes EVERY pending prompt — the mid-run rescue for a live
  /// approval-mode flip to yolo/unattended ("stop asking"). Returns how
  /// many prompts were resolved.
  int resolveAll({required bool allow, required String note}) {
    final ids = _pending.keys.toList();
    for (final id in ids) {
      decide(id, allow);
      _sink({
        'type': 'approval_resolved',
        'id': id,
        'allow': allow,
        'note': note,
      });
    }
    return ids.length;
  }

  static String _encode(Map<String, dynamic> arguments) {
    try {
      return jsonEncode(arguments);
    } on Object {
      return '$arguments';
    }
  }
}

/// Whether the exfil gate's ask reaches a human under [mode]. yolo means
/// ZERO prompts in the extension (there is no `bash` there to carry
/// critical patterns), and unattended never blocks — both answer the ask
/// without a dialog; only the interactive modes (ask/write) surface it.
bool exfilGateShouldAsk(ApprovalMode mode) =>
    mode == ApprovalMode.alwaysAsk || mode == ApprovalMode.write;

/// Whether a reconfigure needs an idle host. The approval mode is the one
/// field that applies live (mid-run included) — everything else
/// (provider, model, mailbox, hub target, tool visibility) is unsafe to
/// swap under a running turn and keeps the busy error.
bool reconfigureNeedsIdle({
  required bool mailboxChanged,
  required bool providerChanged,
  required bool dapChanged,
  required bool toolsChanged,
}) => mailboxChanged || providerChanged || dapChanged || toolsChanged;
