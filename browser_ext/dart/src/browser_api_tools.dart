// Browser-power tool surface (issue #30 v2.1): 34 tools over the typed
// [ChromeApi] facade, the v2 successor of the v1 `browser_*` family in
// lib/src/browser/browser_tools.dart (same discipline: JSON-schema-style
// parameter maps, terse descriptions, throw-on-failure so the error code
// rides the tool-result message the model reads).
//
// Policy is deliberately layered, not mixed:
// - chrome_api.dart turns raw chrome failures into coded
//   ChromeApiException (one stable machine vocabulary);
// - THIS file adds tool-surface policy on top: the restricted-page rule
//   (E1/E17 — scripting+debugger refused with 'restricted_page', tab
//   management still allowed), the inject_js result budget (E4), the
//   structured page-error mapping (E2 — a failed page evaluation is DATA
//   the model reads, never a raw throw), the retryable
//   'execution_context_destroyed' surfacing (E3), and the targeted
//   refusals ('active_tab', 'no_longer_available', 'no_app_page'); plus
//   the issue #30 v2.1 gates: prompt-injection refusals ('login_form',
//   'keylogger_shaped'), exfil-gate approval holds ('approval_required')
//   on outbound tabs/downloads, and redaction+quarantine of page-derived
//   READ results;
// - approval tiers are metadata here ([BrowserToolSpec]); enforcement
//   lives in the host approval gate.
//
// Pure Dart — compiled into the MV3 service worker: no dart:io, no
// js_interop. Tests drive the whole surface through fake_chrome.dart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/agent/tool_registry.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/redact/redaction_pipeline.dart';

import 'chrome_api.dart';
import 'security/exfil_gate.dart';
import 'security/injection_validator.dart';
import 'security/quarantine.dart';

/// Per-frame serialized-result budget for inject_js (E4). 64 KiB keeps a
/// runaway page expression from flooding the model's context window; the
/// surface constructor widens it when a caller needs more.
const defaultResultBudgetBytes = 64 * 1024;

/// Where a tool sits in the panel's permission UX: `core` tools ship with
/// the default tool set, `secondTier` ones only surface in power mode.
enum BrowserToolVisibility { core, secondTier }

/// Registry metadata for one tool (name, chrome permissions it needs,
/// approval tier, visibility, whether the host must prompt on every call).
/// Names are stable wire identifiers — sibling surfaces cross-check them.
final class BrowserToolSpec {
  const BrowserToolSpec({
    required this.name,
    required this.permissions,
    required this.tier,
    this.visibility = BrowserToolVisibility.core,
    this.alwaysPrompts = false,
  });

  final String name;
  final Set<String> permissions;
  final ApprovalTier tier;
  final BrowserToolVisibility visibility;
  final bool alwaysPrompts;
}

/// The spec table for the whole family, in registration order. inject_js is
/// the one always-prompting tool: it runs page-authored code in the page's
/// MAIN world where a hostile page can read the user's session — the host
/// gate asks every time, regardless of session approval mode.
List<BrowserToolSpec> browserApiToolSpecs() => List.unmodifiable(const [
  // tabs — current-tab reads are pre-approved (read tier), cross-tab
  // mutations are write.
  BrowserToolSpec(
    name: 'tabs_open',
    permissions: {'tabs'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'tabs_close',
    permissions: {'tabs'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'tabs_update',
    permissions: {'tabs'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'tabs_query',
    permissions: {'tabs'},
    tier: ApprovalTier.read,
  ),
  BrowserToolSpec(
    name: 'tabs_move',
    permissions: {'tabs'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'tabs_group',
    permissions: {'tabs', 'tabGroups'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'tabs_ungroup',
    permissions: {'tabs'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'tabs_reload',
    permissions: {'tabs'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'tabs_discard',
    permissions: {'tabs'},
    tier: ApprovalTier.write,
  ),
  // windows.
  BrowserToolSpec(
    name: 'windows_open',
    permissions: {'windows'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'windows_update',
    permissions: {'windows'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'windows_close',
    permissions: {'windows'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'windows_list',
    permissions: {'windows'},
    tier: ApprovalTier.read,
  ),
  // tab groups.
  BrowserToolSpec(
    name: 'groups_update',
    permissions: {'tabGroups'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'groups_close',
    permissions: {'tabGroups'},
    tier: ApprovalTier.write,
  ),
  // sessions — the recently-closed ring.
  BrowserToolSpec(
    name: 'sessions_recent',
    permissions: {'sessions'},
    tier: ApprovalTier.read,
  ),
  BrowserToolSpec(
    name: 'sessions_restore',
    permissions: {'sessions'},
    tier: ApprovalTier.write,
  ),
  // history + bookmarks.
  BrowserToolSpec(
    name: 'history_search',
    permissions: {'history'},
    tier: ApprovalTier.read,
  ),
  BrowserToolSpec(
    name: 'bookmarks_list',
    permissions: {'bookmarks'},
    tier: ApprovalTier.read,
  ),
  BrowserToolSpec(
    name: 'bookmarks_add',
    permissions: {'bookmarks'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'bookmarks_update',
    permissions: {'bookmarks'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'bookmarks_remove',
    permissions: {'bookmarks'},
    tier: ApprovalTier.write,
  ),
  // downloads.
  BrowserToolSpec(
    name: 'downloads_start',
    permissions: {'downloads'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'downloads_search',
    permissions: {'downloads'},
    tier: ApprovalTier.read,
  ),
  BrowserToolSpec(
    name: 'downloads_cancel',
    permissions: {'downloads'},
    tier: ApprovalTier.write,
  ),
  // cookies.
  BrowserToolSpec(
    name: 'cookies_get',
    permissions: {'cookies'},
    tier: ApprovalTier.read,
  ),
  BrowserToolSpec(
    name: 'cookies_set',
    permissions: {'cookies'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'cookies_remove',
    permissions: {'cookies'},
    tier: ApprovalTier.write,
  ),
  // scripting + debugger (the power surface).
  BrowserToolSpec(
    name: 'inject_js',
    permissions: {'scripting'},
    tier: ApprovalTier.exec,
    alwaysPrompts: true,
  ),
  BrowserToolSpec(
    name: 'inject_css',
    permissions: {'scripting'},
    tier: ApprovalTier.write,
  ),
  BrowserToolSpec(
    name: 'cdp_eval',
    permissions: {'debugger'},
    tier: ApprovalTier.exec,
  ),
  BrowserToolSpec(
    name: 'page_screenshot',
    permissions: {'debugger'},
    tier: ApprovalTier.exec,
  ),
  // The app's own page — the extension body, not user content: read.
  BrowserToolSpec(
    name: 'app_screenshot',
    permissions: {'tabs', 'debugger'},
    tier: ApprovalTier.read,
  ),
  BrowserToolSpec(
    name: 'nav_wait',
    permissions: {'webNavigation'},
    tier: ApprovalTier.read,
  ),
]);

/// Restricted-target rule (E1/E17), the Dart twin of sw/ops.js
/// restrictedReason: chrome://, extension pages, edge://, about:, the
/// Chrome Web Store (both the legacy and the chromewebstore host) and the
/// built-in PDF viewer. `null` means the page is fair game. Bad urls are
/// NOT a restriction — chrome reports them itself.
///
/// Applies to scripting+debugger tools ONLY: open/close/move/group/reload
/// still work on restricted pages (E17), so the agent can always clean up.
String? restrictedReason(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return null; // let chrome report bad urls
  final scheme = u.scheme.toLowerCase();
  const restrictedSchemes = {
    'chrome',
    'chrome-extension',
    'chrome-untrusted',
    'edge',
    'about',
    'devtools',
    'view-source',
  };
  if (restrictedSchemes.contains(scheme)) {
    return '$scheme: pages are restricted';
  }
  final host = u.host.toLowerCase();
  if (host == 'chromewebstore.google.com' ||
      (host == 'chrome.google.com' && u.path.startsWith('/webstore'))) {
    return 'Chrome Web Store is restricted';
  }
  if (scheme == 'file' &&
      RegExp(r'\.pdf$', caseSensitive: false).hasMatch(u.path)) {
    return 'built-in PDF viewer is restricted';
  }
  return null;
}

/// Result-budget clamp (E4): fits [result] inside [budgetBytes] of UTF-8
/// JSON. Oversized results come back as the longest byte-safe prefix of
/// the encoded JSON with `truncated: true` — the encoded prefix is still
/// valid data for the model (it reads the head, knows it is partial) and
/// the flag tells it to narrow the query instead of retrying blind.
/// Precondition: [result] is JSON-able — the facade already guards that
/// (requireJsonable) before tool code ever sees it.
({Object? result, bool truncated}) truncateResult(
  Object? result,
  int budgetBytes,
) {
  final encoded = jsonEncode(result);
  if (utf8.encode(encoded).length <= budgetBytes) {
    return (result: result, truncated: false);
  }
  // Byte length is monotonic in prefix length → binary search the longest
  // prefix that fits (handles multi-byte runes without per-char scans).
  var lo = 0;
  var hi = encoded.length;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (utf8.encode(encoded.substring(0, mid)).length <= budgetBytes) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return (result: encoded.substring(0, lo), truncated: true);
}

/// The only error type this surface throws (v1 BrowserToolException shape
/// plus the retryable flag E3 needs). The code rides the thrown message so
/// the loop's error tool result stays machine-actionable.
final class BrowserApiToolException implements Exception {
  BrowserApiToolException(this.code, this.message, {bool? isRetryable})
    : isRetryable = isRetryable ?? false;

  final String code;
  final String message;
  final bool isRetryable;

  @override
  String toString() =>
      'browser tool error [$code]${isRetryable ? ' (retryable)' : ''}: $message';
}

/// The browser tool family over one [ChromeApi]. Build with [tools] and
/// register through [registerBrowserApiTools]; [resultBudget] widens the
/// per-frame inject_js result budget when a caller knows it needs more;
/// [pageClassifier] swaps the prompt-injection page classifier consulted
/// before every scripting execution (default: the URL heuristic);
/// [visitedOrigins] wires the exfil gate for tabs_open/downloads_start —
/// null keeps the gate off, and a set (even empty) enforces it, an empty
/// set meaning every origin counts as unvisited and prompts.
final class BrowserApiToolSurface {
  BrowserApiToolSurface(
    this._chrome, {
    this.resultBudget = defaultResultBudgetBytes,
    this.pageClassifier = urlHeuristicClassifier,
    this.visitedOrigins,
  });

  final ChromeApi _chrome;

  /// Serialized-bytes budget per injected frame result (E4).
  final int resultBudget;

  /// Page classifier consulted before every inject_js / cdp_eval run.
  final PageClassifier pageClassifier;

  /// Origins the user actually visited; null = exfil gate off.
  final Set<String>? visitedOrigins;

  final InjectionValidator _injection = const InjectionValidator();
  final ExfilGate _exfilGate = const ExfilGate();

  /// Masks planted page secrets in page-derived READ results. Heuristic
  /// layers only — no registered secrets at this layer.
  final RedactionPipeline _redactor = RedactionPipeline(
    registeredSecrets: const [],
  );

  static final Map<String, BrowserToolSpec> _specsByName = {
    for (final s in browserApiToolSpecs()) s.name: s,
  };

  /// Builds the whole family (34 tools), names matching
  /// [browserApiToolSpecs] exactly.
  List<AgentTool> tools() {
    AgentTool tool(
      String name,
      String description,
      Map<String, Object?> properties,
      List<String> required,
      Future<ToolExecutionResult> Function(Map<String, dynamic> args) run,
    ) {
      final spec = _specsByName[name];
      if (spec == null) {
        throw StateError('tool "$name" has no BrowserToolSpec entry');
      }
      return AgentTool(
        name: name,
        label: name,
        description: description,
        tier: spec.tier,
        parameters: {
          'type': 'object',
          'properties': properties,
          'required': required,
        },
        execute: (arguments, cancelToken, onUpdate) async {
          cancelToken?.throwIfCancelled();
          try {
            return await run(arguments);
          } on ChromeApiException catch (e) {
            throw BrowserApiToolException(
              e.code,
              e.message,
              isRetryable: e.isRetryable,
            );
          }
        },
      );
    }

    return [
      // ---------------------------------------------------------------------
      // tabs
      // ---------------------------------------------------------------------
      tool(
        'tabs_open',
        'Opens a new tab with a URL. Returns the new tab id. Works on any '
            'page including chrome:// targets.',
        {
          'url': {'type': 'string', 'description': 'URL to open'},
          'active': {
            'type': 'boolean',
            'description': 'make it the active tab (default true)',
          },
          'index': {
            'type': 'integer',
            'description': 'position in the tab strip',
          },
          'pinned': {
            'type': 'boolean',
            'description': 'open pinned (default false)',
          },
        },
        ['url'],
        (args) async {
          final url = _reqStr(args, 'url');
          await _gateOutbound(OutboundKind.windowOpen, url);
          final active = _optBool(args, 'active');
          final index = _optInt(args, 'index');
          final pinned = _optBool(args, 'pinned');
          final t = await _chrome.tabs.create(
            url: url,
            active: active,
            index: index,
            pinned: pinned,
          );
          return ToolExecutionResult.text('opened tab ${t.id} → ${t.url}');
        },
      ),
      tool(
        'tabs_close',
        'Closes one or more tabs by id. Ids come from tabs_query results.',
        {'tabIds': _intListProp('tab ids to close')},
        ['tabIds'],
        (args) async {
          final ids = _reqIntList(args, 'tabIds');
          for (final id in ids) {
            await _chrome.tabs.close(id);
          }
          return ToolExecutionResult.text('closed ${ids.length} tab(s)');
        },
      ),
      tool(
        'tabs_update',
        'Updates one tab: navigate it, activate it, pin or mute it.',
        {
          'tabId': _intProp('tab to update'),
          'url': {
            'type': 'string',
            'description': 'URL to navigate the tab to',
          },
          'active': {'type': 'boolean', 'description': 'activate the tab'},
          'pinned': {'type': 'boolean', 'description': 'pin state'},
          'muted': {'type': 'boolean', 'description': 'mute state'},
        },
        ['tabId'],
        (args) async {
          final tabId = _reqInt(args, 'tabId');
          final url = _optStr(args, 'url');
          final active = _optBool(args, 'active');
          final pinned = _optBool(args, 'pinned');
          final muted = _optBool(args, 'muted');
          final t = await _chrome.tabs.update(
            tabId,
            url: url,
            active: active,
            pinned: pinned,
            muted: muted,
          );
          return ToolExecutionResult.text('updated tab ${t.id} → ${t.url}');
        },
      ),
      tool(
        'tabs_query',
        'Lists tabs matching filters (all filters optional; none = every '
            'tab). url/title are chrome match patterns: `*` is a wildcard, '
            'no `*` means exact match. Returns JSON tab snapshots.',
        {
          'url': {'type': 'string', 'description': 'match pattern on the URL'},
          'title': {
            'type': 'string',
            'description': 'match pattern on the title',
          },
          'groupId': _intProp('only tabs in this group'),
          'pinned': {'type': 'boolean', 'description': 'filter on pinned'},
          'muted': {'type': 'boolean', 'description': 'filter on muted'},
          'active': {'type': 'boolean', 'description': 'filter on active'},
          'currentWindow': {
            'type': 'boolean',
            'description': 'restrict to the focused window',
          },
        },
        const [],
        (args) async {
          final url = _optStr(args, 'url');
          final title = _optStr(args, 'title');
          final groupId = _optInt(args, 'groupId');
          final pinned = _optBool(args, 'pinned');
          final muted = _optBool(args, 'muted');
          final active = _optBool(args, 'active');
          final currentWindow = _optBool(args, 'currentWindow');
          final tabs = await _chrome.tabs.query(
            url: url,
            title: title,
            groupId: groupId,
            pinned: pinned,
            muted: muted,
            active: active,
            currentWindow: currentWindow,
          );
          return _json([for (final t in tabs) t.toJson()]);
        },
      ),
      tool(
        'tabs_move',
        'Moves a tab to an index, optionally into another window.',
        {
          'tabId': _intProp('tab to move'),
          'index': _intProp('zero-based target index (clamped)'),
          'windowId': _intProp('destination window (default: current)'),
        },
        ['tabId', 'index'],
        (args) async {
          final tabId = _reqInt(args, 'tabId');
          final index = _reqInt(args, 'index');
          final windowId = _optInt(args, 'windowId');
          final t = await _chrome.tabs.move(
            tabId,
            index: index,
            windowId: windowId,
          );
          return ToolExecutionResult.text(
            'moved tab ${t.id} to index $index in window ${t.windowId}',
          );
        },
      ),
      tool(
        'tabs_group',
        'Groups tabs (creating the group when needed) and optionally names '
            'and colors it. Returns the group id.',
        {
          'tabIds': _intListProp('tabs to group (must share one window)'),
          'groupId': _intProp('existing group to join (default: create one)'),
          'title': {'type': 'string', 'description': 'group title'},
          'color': {
            'type': 'string',
            'description': "chrome color name, e.g. 'blue', 'green', 'red'",
          },
        },
        ['tabIds'],
        (args) async {
          final tabIds = _reqIntList(args, 'tabIds');
          final groupId = _optInt(args, 'groupId');
          final title = _optStr(args, 'title');
          final color = _optStr(args, 'color');
          final gid = await _chrome.tabs.group(
            tabIds: tabIds,
            groupId: groupId,
            title: title,
            color: color,
          );
          return ToolExecutionResult.text('tabs grouped into group $gid');
        },
      ),
      tool(
        'tabs_ungroup',
        'Removes tabs from their tab groups.',
        {'tabIds': _intListProp('tabs to ungroup')},
        ['tabIds'],
        (args) async {
          final ids = _reqIntList(args, 'tabIds');
          await _chrome.tabs.ungroup(ids);
          return ToolExecutionResult.text('ungrouped ${ids.length} tab(s)');
        },
      ),
      tool(
        'tabs_reload',
        'Reloads a tab, optionally bypassing the cache.',
        {
          'tabId': _intProp('tab to reload'),
          'bypassCache': {
            'type': 'boolean',
            'description': 'skip the HTTP cache (default false)',
          },
        },
        ['tabId'],
        (args) async {
          final tabId = _reqInt(args, 'tabId');
          final bypassCache = _optBool(args, 'bypassCache') ?? false;
          await _chrome.tabs.reload(tabId, bypassCache: bypassCache);
          return ToolExecutionResult.text('reloaded tab $tabId');
        },
      ),
      tool(
        'tabs_discard',
        'Discards a background tab to free memory (its reload is lazy). '
            "Refuses a window's ACTIVE tab with code 'active_tab'.",
        {'tabId': _intProp('background tab to discard')},
        ['tabId'],
        (args) async {
          final tabId = _reqInt(args, 'tabId');
          final tab = await _chrome.tabs.get(tabId);
          if (tab.active) {
            throw BrowserApiToolException(
              'active_tab',
              'refusing to discard tab $tabId: it is the active tab of its '
                  'window — activate another tab first',
            );
          }
          final t = await _chrome.tabs.discard(tabId);
          return ToolExecutionResult.text('discarded tab ${t.id}');
        },
      ),

      // -------------------------------------------------------------------
      // windows
      // -------------------------------------------------------------------
      tool(
        'windows_open',
        "Opens a new browser window, optionally with a start URL, as "
            "'normal' or 'popup', with a window state and size.",
        {
          'url': {
            'type': 'string',
            'description': 'start URL (default: new tab page)',
          },
          'type': {'type': 'string', 'description': "'normal' or 'popup'"},
          'state': {
            'type': 'string',
            'description': "'normal', 'minimized', 'maximized' or 'fullscreen'",
          },
          'width': _intProp('window width in px'),
          'height': _intProp('window height in px'),
        },
        const [],
        (args) async {
          final url = _optStr(args, 'url');
          final type = _optStr(args, 'type');
          final state = _optStr(args, 'state');
          final width = _optInt(args, 'width');
          final height = _optInt(args, 'height');
          final w = await _chrome.windows.create(
            url: url,
            type: type,
            state: state,
            width: width,
            height: height,
          );
          return ToolExecutionResult.text(
            'opened window ${w.id} (${w.type}) with ${w.tabIds.length} tab(s)',
          );
        },
      ),
      tool(
        'windows_update',
        'Updates a window: window state and/or focus.',
        {
          'windowId': _intProp('window to update'),
          'state': {
            'type': 'string',
            'description': "'normal', 'minimized', 'maximized' or 'fullscreen'",
          },
          'focused': {'type': 'boolean', 'description': 'focus the window'},
        },
        ['windowId'],
        (args) async {
          final windowId = _reqInt(args, 'windowId');
          final state = _optStr(args, 'state');
          final focused = _optBool(args, 'focused');
          final w = await _chrome.windows.update(
            windowId,
            state: state,
            focused: focused,
          );
          return ToolExecutionResult.text(
            'updated window ${w.id} (state ${w.state})',
          );
        },
      ),
      tool(
        'windows_close',
        'Closes a window and every tab in it.',
        {'windowId': _intProp('window to close')},
        ['windowId'],
        (args) async {
          final windowId = _reqInt(args, 'windowId');
          await _chrome.windows.close(windowId);
          return ToolExecutionResult.text('closed window $windowId');
        },
      ),
      tool(
        'windows_list',
        'Lists all browser windows with id, type, state, focus, geometry '
            'and tab ids. Returns JSON window snapshots.',
        const {},
        const [],
        (args) async {
          final windows = await _chrome.windows.getAll();
          return _json([for (final w in windows) w.toJson()]);
        },
      ),

      // -------------------------------------------------------------------
      // tab groups
      // -------------------------------------------------------------------
      tool(
        'groups_update',
        'Renames and/or recolors a tab group.',
        {
          'groupId': _intProp('group to update'),
          'title': {'type': 'string', 'description': 'new group title'},
          'color': {
            'type': 'string',
            'description': "chrome color name, e.g. 'blue'",
          },
        },
        ['groupId'],
        (args) async {
          final groupId = _reqInt(args, 'groupId');
          final title = _optStr(args, 'title');
          final color = _optStr(args, 'color');
          final g = await _chrome.groups.update(
            groupId,
            title: title,
            color: color,
          );
          return ToolExecutionResult.text(
            'group ${g.id} updated (title "${g.title}", color ${g.color})',
          );
        },
      ),
      tool(
        'groups_close',
        'Closes a tab group and every tab in it.',
        {'groupId': _intProp('group to close')},
        ['groupId'],
        (args) async {
          final groupId = _reqInt(args, 'groupId');
          await _chrome.groups.close(groupId);
          return ToolExecutionResult.text('closed group $groupId');
        },
      ),

      // -------------------------------------------------------------------
      // sessions
      // -------------------------------------------------------------------
      tool(
        'sessions_recent',
        'Lists recently closed tabs/windows with restorable sessionIds. '
            'Returns JSON session snapshots, newest first.',
        const {},
        const [],
        (args) async {
          final sessions = await _chrome.sessions.getRecentlyClosed();
          return _json([for (final s in sessions) s.toJson()]);
        },
      ),
      tool(
        'sessions_restore',
        'Reopens a recently closed tab or window by sessionId (from '
            "sessions_recent). Gone entries fail cleanly with "
            "'no_longer_available' (E19).",
        {
          'sessionId': {
            'type': 'string',
            'description': 'sessionId from sessions_recent',
          },
        },
        ['sessionId'],
        (args) async {
          final sessionId = _reqStr(args, 'sessionId');
          try {
            final s = await _chrome.sessions.restore(sessionId);
            return _json({'ok': true, 'restored': s.toJson()});
          } on ChromeApiException catch (e) {
            if (e.code == 'no_session') {
              throw BrowserApiToolException(
                'no_longer_available',
                "session '$sessionId' is no longer available — list "
                    'sessions_recent again for fresh ids',
              );
            }
            rethrow;
          }
        },
      ),

      // -------------------------------------------------------------------
      // history + bookmarks
      // -------------------------------------------------------------------
      tool(
        'history_search',
        'Searches browsing history by substring over URL and title. '
            'Returns JSON history entries, newest first.',
        {
          'text': {
            'type': 'string',
            'description': 'substring to match ("" = everything)',
          },
          'maxResults': _intProp('cap on returned entries'),
        },
        ['text'],
        (args) async {
          final text = _reqStr(args, 'text');
          final maxResults = _optInt(args, 'maxResults');
          final items = await _chrome.history.search(
            text: text,
            maxResults: maxResults,
          );
          return _hardenedListJson([
            for (final h in items) h.toJson(),
          ], source: 'history');
        },
      ),
      tool(
        'bookmarks_list',
        'Returns the full bookmark tree as JSON (roots "1" Bookmarks bar '
            'and "2" Other bookmarks always exist).',
        const {},
        const [],
        (args) async {
          final tree = await _chrome.bookmarks.tree();
          return _hardenedListJson([
            for (final n in tree) n.toJson(),
          ], source: 'bookmarks');
        },
      ),
      tool(
        'bookmarks_add',
        'Creates a bookmark (default parent: Bookmarks bar). Returns the '
            'new node id.',
        {
          'title': {'type': 'string', 'description': 'bookmark title'},
          'url': {'type': 'string', 'description': 'bookmark URL'},
          'parentId': _strProp('parent folder id (default: Bookmarks bar)'),
        },
        ['title', 'url'],
        (args) async {
          final title = _reqStr(args, 'title');
          final url = _reqStr(args, 'url');
          final parentId = _optStr(args, 'parentId');
          final n = await _chrome.bookmarks.create(
            title: title,
            url: url,
            parentId: parentId,
          );
          return ToolExecutionResult.text(
            'added bookmark ${n.id}: ${n.title} ${n.url}',
          );
        },
      ),
      tool(
        'bookmarks_update',
        'Renames a bookmark and/or changes its URL.',
        {
          'id': _strProp('bookmark node id'),
          'title': {'type': 'string', 'description': 'new title'},
          'url': {'type': 'string', 'description': 'new URL'},
        },
        ['id'],
        (args) async {
          final id = _reqStr(args, 'id');
          final title = _optStr(args, 'title');
          final url = _optStr(args, 'url');
          final n = await _chrome.bookmarks.update(id, title: title, url: url);
          return ToolExecutionResult.text(
            'updated bookmark ${n.id}: ${n.title} ${n.url}',
          );
        },
      ),
      tool(
        'bookmarks_remove',
        'Removes a bookmark node (not the roots).',
        {'id': _strProp('bookmark node id')},
        ['id'],
        (args) async {
          final id = _reqStr(args, 'id');
          await _chrome.bookmarks.remove(id);
          return ToolExecutionResult.text('removed bookmark $id');
        },
      ),

      // -------------------------------------------------------------------
      // downloads
      // -------------------------------------------------------------------
      tool(
        'downloads_start',
        'Starts downloading a URL; the browser picks the filename unless '
            'one is given. Returns the download id.',
        {
          'url': {'type': 'string', 'description': 'URL to download'},
          'filename': {
            'type': 'string',
            'description': 'target filename relative to Downloads',
          },
        },
        ['url'],
        (args) async {
          final url = _reqStr(args, 'url');
          await _gateOutbound(OutboundKind.download, url);
          final filename = _optStr(args, 'filename');
          final id = await _chrome.downloads.download(
            url: url,
            filename: filename,
          );
          return ToolExecutionResult.text('started download $id from $url');
        },
      ),
      tool(
        'downloads_search',
        'Lists downloads, optionally filtered by a substring over URL or '
            'filename. Returns JSON download entries.',
        {
          'query': {
            'type': 'string',
            'description': 'substring filter (default: all)',
          },
        },
        const [],
        (args) async {
          final query = _optStr(args, 'query');
          final items = await _chrome.downloads.search(query: query);
          return _json([for (final d in items) d.toJson()]);
        },
      ),
      tool(
        'downloads_cancel',
        'Cancels an in-flight download.',
        {'id': _intProp('download id')},
        ['id'],
        (args) async {
          final id = _reqInt(args, 'id');
          await _chrome.downloads.cancel(id);
          return ToolExecutionResult.text('cancelled download $id');
        },
      ),

      // -------------------------------------------------------------------
      // cookies
      // -------------------------------------------------------------------
      tool(
        'cookies_get',
        'Reads one cookie by url + name. Returns JSON, or '
            '`{"ok":true,"cookie":null}` when absent.',
        {
          'url': _strProp('URL whose host scopes the cookie'),
          'name': _strProp('cookie name'),
        },
        ['url', 'name'],
        (args) async {
          final url = _reqStr(args, 'url');
          final name = _reqStr(args, 'name');
          final c = await _chrome.cookies.get(url: url, name: name);
          return _json({'ok': true, 'cookie': c?.toJson()});
        },
      ),
      tool(
        'cookies_set',
        'Writes a cookie scoped to the URL host.',
        {
          'url': _strProp('URL whose host scopes the cookie'),
          'name': _strProp('cookie name'),
          'value': _strProp('cookie value'),
        },
        ['url', 'name', 'value'],
        (args) async {
          final url = _reqStr(args, 'url');
          final name = _reqStr(args, 'name');
          final value = _reqStr(args, 'value');
          await _chrome.cookies.set(url: url, name: name, value: value);
          return ToolExecutionResult.text('set cookie for $url');
        },
      ),
      tool(
        'cookies_remove',
        'Deletes a cookie by url + name (absent cookies are a no-op).',
        {
          'url': _strProp('URL whose host scopes the cookie'),
          'name': _strProp('cookie name'),
        },
        ['url', 'name'],
        (args) async {
          final url = _reqStr(args, 'url');
          final name = _reqStr(args, 'name');
          await _chrome.cookies.remove(url: url, name: name);
          return ToolExecutionResult.text('removed cookie from $url');
        },
      ),

      // -------------------------------------------------------------------
      // scripting + debugger — the power surface. Restricted pages refuse
      // with 'restricted_page' (E1/E17); tab management stays allowed.
      // -------------------------------------------------------------------
      tool(
        'inject_js',
        "Injects JavaScript into a tab and returns one {frameId, result} "
            "entry per frame. world 'ISOLATED' (extension world) or 'MAIN' "
            '(page world — always asks for approval). Page failures come '
            'back as {"ok":false,"error":{code,message}} (E2); oversized '
            'results are truncated with truncated:true (E4); a destroyed '
            "execution context fails with retryable "
            "'execution_context_destroyed' (E3). Restricted pages refuse "
            "with 'restricted_page'.",
        {
          'tabId': _intProp('target tab'),
          'code': {
            'type': 'string',
            'description': 'JavaScript function source to run',
          },
          'world': {
            'type': 'string',
            'description':
                "'ISOLATED' (extension world) or 'MAIN' (page world)",
          },
          'allFrames': {'type': 'boolean', 'description': 'run in every frame'},
          'frameIds': _intListProp('run in these frame ids instead'),
          'timeoutMs': {
            'type': 'integer',
            'description': 'give up after this long (1..120000, default 30000)',
          },
        },
        ['tabId', 'code', 'world'],
        _injectJs,
      ),
      tool(
        'inject_css',
        'Injects CSS into a tab (stays until the page navigates). '
            "Restricted pages refuse with 'restricted_page'.",
        {
          'tabId': _intProp('target tab'),
          'css': {'type': 'string', 'description': 'CSS text to insert'},
          'allFrames': {
            'type': 'boolean',
            'description': 'inject into every frame',
          },
        },
        ['tabId', 'css'],
        (args) async {
          final tabId = _reqInt(args, 'tabId');
          final css = _reqStr(args, 'css');
          final allFrames = _optBool(args, 'allFrames');
          await _restrictScripting(tabId);
          final cssDecision = _injection.validateCss(css);
          if (!cssDecision.allowed) {
            throw BrowserApiToolException(
              cssDecision.code!,
              cssDecision.message!,
            );
          }
          await _chrome.scripting.insertCSS(
            tabId: tabId,
            css: css,
            allFrames: allFrames,
          );
          return ToolExecutionResult.text(
            'injected ${css.length} chars of CSS into tab $tabId',
          );
        },
      ),
      tool(
        'cdp_eval',
        'Evaluates a JavaScript expression in the page via the Chrome '
            'DevTools protocol (attach → Runtime.evaluate → detach). '
            "Reuses an existing debugger session; always detaches what it "
            "attached. Restricted pages refuse with 'restricted_page'.",
        {
          'tabId': _intProp('target tab'),
          'expression': {
            'type': 'string',
            'description': 'JavaScript expression to evaluate',
          },
          'awaitPromise': {
            'type': 'boolean',
            'description': 'await a returned promise before answering',
          },
        },
        ['tabId', 'expression'],
        _cdpEval,
      ),
      tool(
        'page_screenshot',
        'Captures a PNG of a tab (default: the active tab) via the '
            'debugger. Returns the base64 PNG string. Restricted pages '
            "refuse with 'restricted_page'.",
        {
          'tabId': _intProp('tab to capture (default: active tab)'),
          'fullPage': {
            'type': 'boolean',
            'description': 'capture beyond the viewport (default false)',
          },
        },
        const [],
        (args) async {
          final explicit = _optInt(args, 'tabId');
          final fullPage = _optBool(args, 'fullPage') ?? false;
          final tabId = explicit ?? await _activeTabId();
          await _restrictScripting(tabId);
          final data = await _captureScreenshot(tabId, fullPage: fullPage);
          return _json({'ok': true, 'tabId': tabId, 'pngBase64': data});
        },
      ),
      tool(
        'app_screenshot',
        "Captures this extension's own app page (the chrome-extension:// "
            "tab serving /app/, falling back to /panel/) as base64 PNG — "
            "never user content. No app page open fails cleanly with "
            "'no_app_page' (E14).",
        const {},
        const [],
        (args) async {
          final tabs = await _chrome.tabs.query();
          Tab? app;
          for (final t in tabs) {
            if (!t.url.startsWith('chrome-extension://')) continue;
            if (t.url.contains('/app/')) {
              app = t; // /app/ is the canonical surface — wins over /panel/
              break;
            }
            app ??= t.url.contains('/panel/') ? t : null;
          }
          if (app == null) {
            throw BrowserApiToolException(
              'no_app_page',
              'no open chrome-extension:// app page to capture — open the '
                  'panel first',
            );
          }
          final data = await _captureScreenshot(app.id, fullPage: false);
          return _json({
            'ok': true,
            'tabId': app.id,
            'url': app.url,
            'pngBase64': data,
          });
        },
      ),

      // -------------------------------------------------------------------
      // navigation wait
      // -------------------------------------------------------------------
      tool(
        'nav_wait',
        'Waits until a tab completes a main-frame navigation, optionally '
            "matching a URL substring. Times out with retryable 'timeout'.",
        {
          'tabId': _intProp('tab to watch'),
          'urlContains': {
            'type': 'string',
            'description': 'substring the final URL must contain',
          },
          'timeoutMs': {
            'type': 'integer',
            'description': 'give up after this long (1..120000, default 30000)',
          },
        },
        ['tabId', 'timeoutMs'],
        _navWait,
      ),
    ];
  }

  // -------------------------------------------------------------------------
  // Tool bodies that are more than a one-liner
  // -------------------------------------------------------------------------

  /// inject_js (E2/E3/E4): validation and the restricted-page gate throw;
  /// page-level evaluation failures become structured {ok:false} data.
  Future<ToolExecutionResult> _injectJs(Map<String, dynamic> args) async {
    final tabId = _reqInt(args, 'tabId');
    final code = _reqStr(args, 'code');
    final world = args['world'];
    if (world is! String || (world != 'ISOLATED' && world != 'MAIN')) {
      throw BrowserApiToolException(
        'bad_world',
        "argument 'world' must be 'ISOLATED' or 'MAIN'"
            '${world == null ? '' : ', got "$world"'}',
      );
    }
    final timeoutMs = _boundedMs(args, 'timeoutMs');
    final allFrames = _optBool(args, 'allFrames');
    final frameIds = _optIntList(args, 'frameIds');
    await _restrictScripting(tabId);
    await _validateInjection(tabId, code);

    List<ScriptResult> frames;
    try {
      frames = await _chrome.scripting
          .executeScript(
            tabId: tabId,
            world: world,
            allFrames: allFrames,
            frameIds: frameIds,
            funcSource: code,
          )
          .timeout(Duration(milliseconds: timeoutMs));
    } on ChromeApiException catch (e) {
      // E3: a destroyed execution context (frame vanished mid-script) is
      // worth re-running — keep it a retryable throw. Every other failure
      // is the page's own outcome (E2): report as data, never a raw throw.
      if (e.code == 'execution_context_destroyed') rethrow;
      return _structuredError(e.code, e.message);
    } on TimeoutException {
      throw BrowserApiToolException(
        'timeout',
        'inject_js timed out after ${timeoutMs}ms',
        isRetryable: true,
      );
    } on Object catch (e) {
      // The facade's real adapter wraps script failures, but a raw error
      // escaping the boundary (rejected promise, TypeError) still lands
      // here: structured, never a raw crash (E2).
      return _structuredError('page_error', '$e');
    }

    return _json({
      'ok': true,
      'results': [for (final f in frames) _frameEntry(f)],
    });
  }

  /// One inject_js result entry: the frame's value clamped to the budget
  /// (E4) with an explicit truncated flag when clamping happened.
  Map<String, Object?> _frameEntry(ScriptResult f) {
    final t = truncateResult(f.result, resultBudget);
    return {
      'frameId': f.frameId,
      'result': t.result,
      if (t.truncated) 'truncated': true,
    };
  }

  /// cdp_eval: attach (reusing a foreign session), evaluate, detach — but
  /// only what WE attached.
  Future<ToolExecutionResult> _cdpEval(Map<String, dynamic> args) async {
    final tabId = _reqInt(args, 'tabId');
    final expression = _reqStr(args, 'expression');
    final awaitPromise = _optBool(args, 'awaitPromise') ?? false;
    await _restrictScripting(tabId);
    final pageUrl = await _validateInjection(tabId, expression);

    final attached = await _attach(tabId);
    try {
      final response = await _chrome.debugger
          .sendCommand(tabId, 'Runtime.evaluate', {
            'expression': expression,
            'returnByValue': true,
            if (awaitPromise) 'awaitPromise': true,
          });
      final map = response as Map<Object?, Object?>?;
      final details = map?['exceptionDetails'];
      if (details != null) {
        throw BrowserApiToolException(
          'page_error',
          'page threw during evaluate: ${jsonEncode(details)}',
        );
      }
      final value = (map?['result'] as Map<Object?, Object?>?)?['value'];
      return _json({
        'ok': true,
        'tabId': tabId,
        // Page-derived read: redact + quarantine STRING results (the
        // instruction-injection vector); scalars keep their JSON shape.
        'value': value is String
            ? quarantinePageContent(
                source: 'cdp_eval',
                content: _redactor.redact(value),
                url: pageUrl,
              )
            : value,
      });
    } finally {
      if (attached) {
        try {
          await _chrome.debugger.detach(tabId);
        } on ChromeApiException {
          // Someone detached first — nothing left to clean up.
        }
      }
    }
  }

  /// nav_wait: fail fast on a dead tab, then ride webNavigation.onCompleted
  /// (main frame only) until a match or the budget runs out.
  Future<ToolExecutionResult> _navWait(Map<String, dynamic> args) async {
    final tabId = _reqInt(args, 'tabId');
    final urlContains = _optStr(args, 'urlContains');
    final timeoutMs = _boundedMs(args, 'timeoutMs');
    await _chrome.tabs.get(tabId); // no_tab before waiting on a ghost

    // Fake and real adapters keep broadcast streams open; firstWhere's
    // StateError on close cannot fire in practice.
    final nav = await _chrome.webNavigation.onCompleted
        .firstWhere(
          (n) =>
              n.tabId == tabId &&
              n.frameId == 0 && // main frame: subframes are not navigations
              (urlContains == null || n.url.contains(urlContains)),
        )
        .timeout(
          Duration(milliseconds: timeoutMs),
          onTimeout: () => throw BrowserApiToolException(
            'timeout',
            'nav_wait timed out after ${timeoutMs}ms'
                '${urlContains == null ? '' : ' waiting for "$urlContains"'}',
            isRetryable: true,
          ),
        );
    return ToolExecutionResult.text(
      'navigation completed: tab $tabId → ${nav.url}',
    );
  }

  // -------------------------------------------------------------------------
  // Shared machinery
  // -------------------------------------------------------------------------

  /// The restricted-page gate for scripting+debugger tools (E1/E17).
  Future<void> _restrictScripting(int tabId) async {
    final tab = await _chrome.tabs.get(tabId);
    final reason = restrictedReason(tab.url);
    if (reason != null) {
      throw BrowserApiToolException(
        'restricted_page',
        'tab $tabId: $reason — scripting and debugging are refused on this '
            'page (tab management still works)',
      );
    }
  }

  /// Prompt-injection gate for scripting tools (issue #30 v2.1):
  /// classify the page through the [pageClassifier] seam, then validate
  /// the code. A refusal is a structured tool error carrying the
  /// validator's code — counted as a refusal, never a crash. Returns the
  /// page URL for downstream quarantine provenance.
  Future<String> _validateInjection(int tabId, String code) async {
    final tab = await _chrome.tabs.get(tabId);
    final page = await pageClassifier(tabId, tab.url);
    final decision = _injection.validateJs(code: code, page: page);
    if (!decision.allowed) {
      throw BrowserApiToolException(decision.code!, decision.message!);
    }
    return tab.url;
  }

  /// Exfil gate for tabs_open/downloads_start. Tool calls are
  /// user-authorized at this layer (source realUser); the approval
  /// tiering itself stays the host's approval gate — when the gate is
  /// wired (non-null [visitedOrigins]) a requiresApproval verdict
  /// surfaces as 'approval_required' carrying the gate's explanation.
  Future<void> _gateOutbound(OutboundKind kind, String url) async {
    final visited = visitedOrigins;
    if (visited == null) return;
    final action = OutboundAction(
      kind: kind,
      targetOrigin: outboundOrigin(url),
      payloadSnippet: '',
      source: ActionSource.realUser,
    );
    final decision = _exfilGate.evaluate(action, userVisitedOrigins: visited);
    if (decision.requiresApproval) {
      throw BrowserApiToolException(
        'approval_required',
        _exfilGate.explain(action, decision),
      );
    }
  }

  /// Page-derived READ results (history rows, bookmark titles):
  /// redacted through the core pipeline, then quarantined, so planted
  /// page secrets come back masked and page text can never ride back as
  /// instructions.
  ToolExecutionResult _hardenedListJson(
    Object? payload, {
    required String source,
  }) {
    final text = _redactor.redact(jsonEncode(payload));
    return ToolExecutionResult.text(
      quarantinePageContent(source: source, content: text),
    );
  }

  /// Active tab of the focused window, for tabId-optional tools.
  Future<int> _activeTabId() async {
    final tabs = await _chrome.tabs.query(active: true, currentWindow: true);
    if (tabs.isEmpty) {
      throw BrowserApiToolException(
        'no_tab',
        'no active tab in the current window',
      );
    }
    return tabs.first.id;
  }

  /// Attaches the debugger; true when WE attached (false = a session was
  /// already up and the caller must NOT detach it).
  Future<bool> _attach(int tabId) async {
    try {
      await _chrome.debugger.attach(tabId);
      return true;
    } on ChromeApiException catch (e) {
      if (e.code != 'already_attached') rethrow;
      return false;
    }
  }

  /// attach → Page.captureScreenshot → detach. Returns the base64 PNG.
  Future<String> _captureScreenshot(int tabId, {required bool fullPage}) async {
    final attached = await _attach(tabId);
    try {
      final response = await _chrome.debugger.sendCommand(
        tabId,
        'Page.captureScreenshot',
        {'format': 'png', if (fullPage) 'captureBeyondViewport': true},
      );
      final data = (response as Map<Object?, Object?>?)?['data'];
      if (data is! String) {
        throw BrowserApiToolException(
          'cdp_error',
          'Page.captureScreenshot returned no PNG data',
        );
      }
      return data;
    } finally {
      if (attached) {
        try {
          await _chrome.debugger.detach(tabId);
        } on ChromeApiException {
          // Someone detached first — nothing left to clean up.
        }
      }
    }
  }

  ToolExecutionResult _json(Object? payload) =>
      ToolExecutionResult.text(jsonEncode(payload));

  ToolExecutionResult _structuredError(String code, String message) => _json({
    'ok': false,
    'error': {'code': code, 'message': message},
  });
}

// ---------------------------------------------------------------------------
// Argument validation — every failure is a coded BrowserApiToolException
// naming the offending argument, never a cast crash.
// ---------------------------------------------------------------------------

Never _bad(String message) =>
    throw BrowserApiToolException('bad_args', message);

String _reqStr(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is String && v.isNotEmpty) return v;
  _bad("string argument '$key' is required");
}

String? _optStr(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is String) return v;
  _bad("argument '$key' must be a string");
}

int _reqInt(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is int) return v;
  _bad("integer argument '$key' is required");
}

int? _optInt(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is int) return v;
  _bad("argument '$key' must be an integer");
}

bool? _optBool(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is bool) return v;
  _bad("argument '$key' must be a boolean");
}

List<int>? _optIntList(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is List && v.every((e) => e is int)) {
    if (v.isEmpty) _bad("argument '$key' must not be empty");
    return List<int>.of(v.cast<int>());
  }
  _bad("argument '$key' must be an array of integers");
}

List<int> _reqIntList(Map<String, dynamic> args, String key) =>
    _optIntList(args, key) ?? _bad("integer array argument '$key' is required");

/// Timeout budget shared by inject_js / nav_wait: 1..120000 ms.
int _boundedMs(
  Map<String, dynamic> args,
  String key, {
  int defaultValue = 30000,
}) {
  final v = _optInt(args, key) ?? defaultValue;
  if (v < 1 || v > 120000) {
    _bad("argument '$key' must be between 1 and 120000 ms");
  }
  return v;
}

// Schema property shorthand.
Map<String, Object?> _intProp(String d) => {
  'type': 'integer',
  'description': d,
};
Map<String, Object?> _strProp(String d) => {'type': 'string', 'description': d};
Map<String, Object?> _intListProp(String d) => {
  'type': 'array',
  'items': {'type': 'integer'},
  'description': d,
};

/// Registers the whole browser-API family on [registry]. Names are the
/// [browserApiToolSpecs] entries — one registration path for every host
/// (SW agent host today, panel tooling later).
void registerBrowserApiTools(ToolRegistry registry, ChromeApi chrome) {
  registry.registerAll(BrowserApiToolSurface(chrome).tools());
}
