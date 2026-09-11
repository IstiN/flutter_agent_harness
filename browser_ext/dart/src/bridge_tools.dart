// The generic chrome.* bridge (issue #137): two agent tools exposing the
// WHOLE declared chrome surface — `browser_api_catalog` (what exists:
// namespaces, methods, arities, events) and `browser_api` (call any
// method by path). The curated family (browser_api_tools.dart) stays
// byte-identical; this surface covers the long tail it never wrapped.
//
// Design pins:
//  * error-as-data — bridge failures return {ok:false,error:{code,…}},
//    never throw (the turn continues; the model adapts);
//  * hard deny list (management, runtime) enforced in EVERY mode — an
//    injected page must not reach the extension's own machinery;
//  * per-root risk map (bridgeRiskTier) drives a dynamic exec-tier ask;
//    read/write ride their static tiers like every other tool;
//  * page-derived results are redacted + UNTRUSTED-quarantined + capped.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/agent/tool_registry.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/redact/redaction_pipeline.dart';
import 'package:flutter_agent_harness/src/types.dart';

import 'browser_api_tools.dart' show truncateResult;
import 'chrome_api.dart';
import 'security/quarantine.dart';

/// Path validation failure. [code] ∈ {bad_path, denied_namespace}.
final class BridgePathException implements Exception {
  BridgePathException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BridgePathException($code): $message';
}

/// Hard deny roots — enforced in every mode including yolo/unattended.
///
/// * `management` — issue #137 names it explicitly: a page that phished
///   the model into management.setEnabled(false) would uninstall the
///   agent's own oversight; self-preservation outranks generality.
/// * `runtime` — the extension's own machinery (getBackgroundPage,
///   sendMessage, reload…): the facade's internal runtime hops are NOT
///   bridge-path calls and stay unaffected; only model-driven paths deny.
const Set<String> bridgeDeniedNamespaces = {'management', 'runtime'};

/// Roots whose methods execute code or speak for the user: the bridge
/// prompts before every call (approval matrix "exec + alwaysPrompts").
const Set<String> _execRoots = {
  'scripting', 'debugger', 'cookies', 'browsingData', 'webRequest',
  'declarativeNetRequest', 'proxy', 'privacy', 'tabCapture',
  'nativeMessaging',
};

/// Root-namespace → approval tier for the dynamic bridge gate. Unknown
/// roots default to [ApprovalTier.exec] — an API newer than this map is
/// treated as dangerous until proven otherwise (AC5e).
ApprovalTier bridgeRiskTier(String root) =>
    root == 'chrome' || _execRoots.contains(root) || !_readRoots.contains(root)
    ? ApprovalTier.exec
    : ApprovalTier.read;

/// Roots known to be pure read/surface state — everything not listed
/// here and not in [_execRoots] is also exec-by-default, so this set is
/// the allowlist that downgrades.
const Set<String> _readRoots = {
  'tabs', 'windows', 'tabGroups', 'sessions', 'history', 'bookmarks',
  'downloads', 'storage', 'alarms', 'notifications', 'action', 'offscreen',
  'power', 'idle', 'contextMenus', 'omnibox', 'commands', 'webNavigation',
  'system', 'sidePanel', 'identity', 'readingList', 'search', 'tts',
  'i18n', 'extension',
};

/// One hard cap for bridge results (64 KiB, the curated family's budget).
const int bridgeResultBudgetBytes = 64 * 1024;

/// A bridge call that never settles (callback-only API without callback
/// semantics, hung IPC) fails loudly after this instead of hanging the
/// turn.
const Duration _bridgeCallTimeout = Duration(seconds: 30);

/// Parsed bridge path. [ns] is the full namespace (may be dotted:
/// `storage.local`); [root] is its first segment (risk map + deny key);
/// [method] is the final segment.
typedef BridgePath = ({String root, String ns, String method});

/// Segment-level prototype-pollution guard: the classic keys plus any
/// event name (`on[A-Z]…` — events are not bridge-callable in v1).
bool _segmentDenied(String s) =>
    s == '__proto__' || s == 'constructor' || s == 'prototype' ||
    (s.length > 2 && s.startsWith('on') &&
        _isUpper(s.codeUnitAt(2)));

bool _isUpper(int c) => c >= 0x41 && c <= 0x5A;

/// Validates and parses `chrome.<ns…>.<method>`. Throws
/// [BridgePathException] on anything else — the caller turns it into the
/// {ok:false} data error.
BridgePath parseBridgePath(String path) {
  if (!path.startsWith('chrome.')) {
    throw BridgePathException(
      'bad_path',
      'path must start with "chrome." (got "$path")',
    );
  }
  final rest = path.substring('chrome.'.length);
  final segments = rest.split('.');
  if (segments.length < 2) {
    throw BridgePathException(
      'bad_path',
      'need at least chrome.<namespace>.<method>',
    );
  }
  for (final s in segments) {
    if (s.isEmpty) {
      throw BridgePathException('bad_path', 'empty segment in "$path"');
    }
    if (_segmentDenied(s)) {
      throw BridgePathException(
        'bad_path',
        'segment "$s" is not callable through the bridge',
      );
    }
  }
  final root = segments.first;
  if (bridgeDeniedNamespaces.contains(root)) {
    throw BridgePathException(
      'denied_namespace',
      'chrome.$root is denied on the bridge in every mode '
          '(see docs/browser-extension.md)',
    );
  }
  return (
    root: root,
    ns: segments.sublist(0, segments.length - 1).join('.'),
    method: segments.last,
  );
}

/// The dynamic risk ask: prompt (or auto-allow per approval mode) before
/// an exec-tier namespace call. Returns whether the call may proceed.
typedef BridgeRiskAsk = Future<bool> Function(String path, ApprovalTier tier);

/// One-time notice hook — the host uses it for the yolo-mode banner.
typedef BridgeFirstCall = void Function(String path);

/// Registers `browser_api_catalog` + `browser_api` (exactly two tools —
/// the curated family is untouched; REG pins the +2 contract).
Future<void> registerBridgeTools(
  ToolRegistry registry,
  ChromeApi chrome, {
  BridgeRiskAsk? riskAsk,
  BridgeFirstCall? onFirstCall,
}) async {
  final bridge = chrome.bridge;
  var firstCallSeen = false;
  final redactor = RedactionPipeline(registeredSecrets: const []);

  ToolExecutionResult json(Map<String, Object?> payload) =>
      ToolExecutionResult.text(jsonEncode(payload));

  ToolExecutionResult err(String code, String message) =>
      json({'ok': false, 'error': {'code': code, 'message': message}});

  registry.registerAll([
    AgentTool(
      name: 'browser_api_catalog',
      label: 'browser_api_catalog',
      description: 'Lists the chrome.* APIs this browser actually granted '
          'the extension (the bridge never speculates: an ungranted API is '
          'absent, not empty). With namespace: that namespace\'s methods '
          '(name → declared parameter count), events, and child '
          'namespaces (storage.local shape). Use it to discover surfaces '
          'no dedicated tool covers, then call them via browser_api.',
      tier: ApprovalTier.read,
      parameters: const {
        'type': 'object',
        'properties': {
          'namespace': {
            'type': 'string',
            'description': 'e.g. "tabs", "storage" or "storage.local" '
                '(omit to list available namespaces)',
          },
        },
        'required': [],
      },
      execute: (arguments, cancelToken, onUpdate) async {
        cancelToken?.throwIfCancelled();
        final ns = arguments['namespace'] as String?;
        try {
          if (ns == null || ns.isEmpty) {
            return json({'ok': true, 'namespaces': await bridge.namespaces()});
          }
          return json({'ok': true, 'namespace': ns, ...await bridge.namespace(ns)});
        } on ChromeApiException catch (e) {
          return err(e.code, e.message);
        } on Object catch (e) {
          return err('bridge_error', '$e');
        }
      },
    ),
    AgentTool(
      name: 'browser_api',
      label: 'browser_api',
      description: 'Calls any chrome.* method the catalog lists — the long '
          'tail beyond the dedicated browser_* tools. path is the full '
          'chrome.<namespace>.<method> (e.g. "chrome.idle.queryState"); '
          'args is the verbatim positional argument list (e.g. '
          '[{"url": "*://example.com/*"}] for tabs.query). Failures come '
          'back as {"ok":false,"error":{code,message}} data — inspect and '
          'adapt, the turn continues. Results are capped at 64 KiB and '
          'wrapped as UNTRUSTED page content. chrome.management and '
          'chrome.runtime are denied in every mode. For code injection '
          'prefer inject_js (scripting.executeScript through the bridge '
          'cannot carry a source string — MV3 CSP blocks eval; files[] '
          'works).',
      tier: ApprovalTier.read,
      parameters: const {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'full method path, "chrome.<ns>.<method>"',
          },
          'args': {
            'type': 'array',
            'description': 'positional arguments as JSON (default: none)',
            'items': {},
          },
        },
        'required': ['path'],
      },
      execute: (arguments, cancelToken, onUpdate) async {
        cancelToken?.throwIfCancelled();
        final path = arguments['path'] as String?;
        if (path == null || path.isEmpty) {
          return err('bad_args', 'string argument "path" is required');
        }
        final BridgePath parsed;
        try {
          parsed = parseBridgePath(path);
        } on BridgePathException catch (e) {
          return err(e.code, e.message);
        }
        final rawArgs = arguments['args'];
        if (rawArgs != null && rawArgs is! List) {
          return err('bad_args', '"args" must be an array');
        }
        final args = [for (final a in (rawArgs as List?) ?? const []) a];

        // Dynamic exec-tier gate: the static tier is read (so the approval
        // matrix never double-prompts); exec-tier namespaces ask here,
        // mode-suppressed by the host (yolo/unattended auto-allow).
        final tier = bridgeRiskTier(parsed.root);
        if (tier == ApprovalTier.exec && riskAsk != null) {
          if (!await riskAsk(path, tier)) {
            return err(
              'approval_required',
              'chrome.$path was not approved '
                  '(${parsed.root} is an exec-tier namespace)',
            );
          }
        }

        if (!firstCallSeen) {
          firstCallSeen = true;
          onFirstCall?.call(path);
        }

        final Object? result;
        try {
          result = await bridge
              .call('${parsed.ns}.${parsed.method}', args)
              .timeout(_bridgeCallTimeout);
        } on ChromeApiException catch (e) {
          return err(e.code, e.message);
        } on TimeoutException {
          return err(
            'timeout',
            'chrome.$path did not settle within '
                '${_bridgeCallTimeout.inSeconds}s',
          );
        } on Object catch (e) {
          return err('bridge_error', '$e');
        }

        // Hygiene (AC7): JSON guard → 64 KiB cap → redact → UNTRUSTED.
        Object? safe;
        var truncated = false;
        try {
          final t = truncateResult(result, bridgeResultBudgetBytes);
          safe = t.result;
          truncated = t.truncated;
        } on Object {
          safe = {
            'non-JSON':
                'chrome.$path returned ${result.runtimeType} — not '
                'JSON-serializable',
          };
        }
        final envelope = {
          'ok': true,
          'path': path,
          'result': safe,
          if (truncated) 'truncated': true,
        };
        return ToolExecutionResult.text(
          quarantinePageContent(
            source: 'browser_api',
            content: redactor.redact(jsonEncode(envelope)),
          ),
        );
      },
    ),
  ]);
}
