// Outbound-action exfiltration gate (issue #30 v2.1).
//
// [ExfilGate] reasons about every action that moves data or control out
// of the browser context (fetch, clipboard write, download, window open,
// mail send) and decides whether the host's approval gate must ask the
// user first. The core rule: page-derived data can REQUEST an action,
// never GRANT it — so anything sourced from page content or tool output
// needs approval even when the target origin is one the user knows.
//
// Pure Dart — compiled into the MV3 service worker: no dart:io, no
// js_interop.
library;

/// What kind of outbound action is being attempted.
enum OutboundKind { fetch, clipboardWrite, download, windowOpen, mailSend }

/// Where the action's content came from.
///
/// - [realUser]: the user (or the host on their behalf) authored it —
///   tool calls are user-authorized at this layer.
/// - [pageContent] / [toolOutput]: the payload was read off a page or out
///   of a tool result, so it may be a prompt-injection request.
enum ActionSource { realUser, pageContent, toolOutput }

/// One outbound action the gate evaluates.
final class OutboundAction {
  const OutboundAction({
    required this.kind,
    required this.targetOrigin,
    required this.payloadSnippet,
    required this.source,
  });

  final OutboundKind kind;

  /// Origin the action targets (e.g. `https://evil.example`).
  final String targetOrigin;

  /// Head of the payload that would leave the browser context; empty
  /// when the action carries no data (a plain window open, a fetch with
  /// no body).
  final String payloadSnippet;

  final ActionSource source;
}

/// The gate's verdict: whether the host approval gate must ask, and why.
final class GateDecision {
  const GateDecision({
    required this.requiresApproval,
    required this.attribution,
  });

  final bool requiresApproval;

  /// Stable attribution: `'page_derived'`, `'cross_origin'`,
  /// `'data_exit'`, or `'user_initiated'` for allowed actions.
  final String attribution;
}

/// The origin-side half of the gate: parses [url] down to a stable origin
/// string. Non-http(s) schemes (`chrome://`, `about:`) get a
/// `scheme://host` fallback so they still attribute to something.
String outboundOrigin(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  try {
    return uri.origin;
  } on StateError {
    return '${uri.scheme}://${uri.host}';
  }
}

/// Origin for seeding the user-visited set (issue #30 v2.1 SW wiring):
/// the same normalizer the gate compares against ([outboundOrigin]) —
/// chrome:// pages keep their `scheme://host` form so ordinary browsing
/// of settings pages never trips a cross-origin prompt — but `null` for
/// urls that carry no origin at all (bad/relative/`data:`/`about:blank`),
/// which must not enter the visited set.
String? originOf(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) return null;
  return outboundOrigin(url);
}

/// Decides which outbound actions need user approval before they run.
/// Pure and stateless — one check per call site.
final class ExfilGate {
  const ExfilGate();

  /// Evaluates [a] against the origins the user has actually visited.
  ///
  /// - Page-derived or tool-output-sourced actions ALWAYS require
  ///   approval, even to visited origins (`'page_derived'`).
  /// - `clipboardWrite`/`mailSend` with a non-empty payload require
  ///   approval regardless of origin — data leaves the browser context
  ///   (`'data_exit'`).
  /// - Real-user actions to an unvisited origin require approval
  ///   (`'cross_origin'`).
  /// - Real-user actions to a visited origin are allowed — no
  ///   false-positive lockout for ordinary browsing.
  GateDecision evaluate(
    OutboundAction a, {
    required Set<String> userVisitedOrigins,
  }) {
    if (a.source != ActionSource.realUser) {
      return const GateDecision(
        requiresApproval: true,
        attribution: 'page_derived',
      );
    }
    final dataLeaves =
        (a.kind == OutboundKind.clipboardWrite ||
            a.kind == OutboundKind.mailSend) &&
        a.payloadSnippet.isNotEmpty;
    if (dataLeaves) {
      return const GateDecision(
        requiresApproval: true,
        attribution: 'data_exit',
      );
    }
    if (!userVisitedOrigins.contains(a.targetOrigin)) {
      return const GateDecision(
        requiresApproval: true,
        attribution: 'cross_origin',
      );
    }
    return const GateDecision(
      requiresApproval: false,
      attribution: 'user_initiated',
    );
  }

  /// Approval-prompt text for [decision] about [action]: names the kind,
  /// the origin and the attribution so the user can judge in one read.
  String explain(OutboundAction action, GateDecision decision) {
    final kind = action.kind.name;
    final origin = action.targetOrigin;
    switch (decision.attribution) {
      case 'page_derived':
        return 'Approval required: $kind to $origin carries page-derived '
            'content [page_derived] — page text can request an action, '
            'never grant it';
      case 'cross_origin':
        return 'Approval required: $kind targets $origin, which the user '
            'has not visited [cross_origin]';
      case 'data_exit':
        return 'Approval required: $kind moves data out of the browser '
            'context toward $origin [data_exit]';
      default:
        return '$kind to $origin allowed [user_initiated]';
    }
  }
}
