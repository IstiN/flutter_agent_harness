// Pure-Dart approval-flow core for the Office taskpane host (issue #89):
// the Office twin of the extension's approval_flow.dart. The host
// (agent_host.dart) wires Office.js and cannot run on the VM; this module
// carries the DECISION logic so tests can pin it:
//
//   - pending prompts keyed `ap-N` with a deny backstop after [timeout]
//     (120s in production; injectable so tests never await it);
//   - the taskpane's decide path (`decide(id, allow)`);
//   - `resolveAll` — the mid-run rescue for a live approval-mode flip to
//     yolo/unattended, completing every pending prompt at once.
//
// Wire shapes: `approval_request` {id, toolName, arguments, reason} and
// `approval_resolved` {id, allow, note}. read_attachment and
// insert_draft_body ride per-tool always-prompt overrides (see
// outlook_tools.dart), so this flow asks on every call of theirs in EVERY
// session mode.
import 'dart:async';

/// Wire-event sink (the host's event bridge): one JSON-able map per event.
typedef OfficeEventSink = void Function(Map<String, dynamic> event);

/// How long an unanswered prompt pends before the conservative deny. The
/// taskpane's only backstop when no surface is around to answer.
const approvalBackstopTimeout = Duration(seconds: 120);

/// Pending-approval bookkeeping for one host: create prompts, answer them
/// from the taskpane, time out the unanswered, and bulk-resolve on a mode
/// change.
final class OfficeApprovalFlow {
  OfficeApprovalFlow({
    required this._sink,
    this.timeout = approvalBackstopTimeout,
  });

  /// How long an unanswered prompt pends before the deny backstop.
  final Duration timeout;

  final OfficeEventSink _sink;
  final _pending = <String, Completer<bool>>{};
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
    _sink({
      'type': 'approval_request',
      'id': id,
      'toolName': toolName,
      'arguments': arguments,
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

  /// The taskpane answered a banner. Unknown/already-resolved ids are a
  /// false no-op (late double-answers).
  bool decide(String id, bool allow) {
    final completer = _pending.remove(id);
    if (completer == null) return false;
    if (!completer.isCompleted) completer.complete(allow);
    return true;
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
}
