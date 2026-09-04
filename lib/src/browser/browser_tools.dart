/// Browser-control tools (issue #23): the `browser_*` tool family over an
/// injectable [BrowserController] seam.
///
/// The family is transport-agnostic — the controller interface is typed per
/// bridge op, and the bridge-backed implementation lives in the executable
/// (`bin/fah.dart`), which routes every op through
/// `BridgeConnection.dispatch` and maps failures to [BrowserToolException]
/// with the contract's wire error codes (`local://bridge_contract.md`).
/// Tools throw on failure (pi semantics): the loop converts the throw into
/// an error tool result whose message carries the contract code (`timeout`,
/// `node_vanished`, `restricted_page`, …) so the model can react.
///
/// Pure Dart: no `dart:io`. Screenshots persist through an injected
/// [browserTools] `saveScreenshot` callback (hosts with io use
/// [saveBrowserScreenshot]; web hosts pass their own).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../env/execution_env.dart';
import '../types.dart';

/// The controller seam behind every `browser_*` tool: one typed method per
/// bridge browser op. Implementations throw [BrowserToolException] with the
/// contract error codes.
abstract interface class BrowserController {
  /// Navigates a tab; returns the tab id, final URL, and page title.
  Future<BrowserNavigation> navigate(String url, {int? tabId});

  /// Every open tab (id, url, title, active flag, tab group).
  Future<List<BrowserTab>> listTabs();

  /// Makes [tabId] the active tab.
  Future<void> switchTab(int tabId);

  /// Clicks the first element matching [selector].
  Future<void> click(String selector, {int? tabId});

  /// Types [text] into [selector], optionally pressing Enter afterwards.
  Future<void> type(String selector, String text, {bool submit, int? tabId});

  /// Presses [key], optionally focused on [selector].
  Future<void> pressKey(String key, {String? selector, int? tabId});

  /// Selects [value] in the `<select>` matching [selector].
  Future<void> select(String selector, String value, {int? tabId});

  /// Reads a bounded serialized DOM subtree.
  Future<BrowserDom> readDom({
    String? selector,
    int? maxNodes,
    bool includeShadow,
    int? tabId,
  });

  /// Evaluates JavaScript in the page's isolated world; a returned Promise
  /// is awaited and its resolution is the result.
  Future<Object?> evalCode(String code, {int? tabId});

  /// Captures a PNG screenshot of a tab.
  Future<Uint8List> screenshot({int? tabId});

  /// Waits until [text] appears or [selector] matches, up to [timeoutMs].
  Future<BrowserWaitResult> waitFor({
    String? selector,
    String? text,
    required int timeoutMs,
    int? tabId,
  });

  /// Cleans the task's tab group (agent-opened tabs only).
  Future<void> taskEnd();

  /// Whether a browser backend is usable right now — the availability
  /// floor for the whole `browser` family (CLI: an extension is paired).
  bool get attached;

  /// Fires when [attached] flips; the host rebuilds tool availability.
  void Function(bool attached)? onAvailabilityChanged;
}

/// One tab as reported by [BrowserController.listTabs].
typedef BrowserTab = ({
  int id,
  String url,
  String title,
  bool active,
  int? groupId,
});

/// The outcome of [BrowserController.navigate].
typedef BrowserNavigation = ({int tabId, String url, String title});

/// The outcome of [BrowserController.readDom].
typedef BrowserDom = ({String dom, int nodeCount, bool truncated});

/// The outcome of [BrowserController.waitFor].
typedef BrowserWaitResult = ({bool found, int waitedMs});

/// A browser-op failure carrying the contract's wire error code
/// (`no_target`, `node_vanished`, `restricted_page`, `timeout`, …). The
/// code rides the thrown message so the model can read and react to it.
final class BrowserToolException implements Exception {
  BrowserToolException(this.code, this.message);

  /// The contract wire code.
  final String code;

  /// Human-readable detail.
  final String message;

  @override
  String toString() => 'browser $code: $message';
}

/// Shared tool-description fragments (every op takes the optional `tabId`
/// pin; restricted pages are contract-pinned as unautomatable).
const _tabPin =
    'tabId (optional integer) pins the op to that tab — ids come from '
    'browser_tabs or a browser_navigate result; omit it for the active tab.';
const _restrictedNote =
    'Restricted pages (chrome://, Chrome Web Store, PDF viewer) fail with '
    'restricted_page.';

String _reqString(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is String && value.isNotEmpty) return value;
  throw BrowserToolException('bad_args', '$key is required');
}

int _reqInt(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value is int) return value;
  throw BrowserToolException('bad_args', '$key (integer) is required');
}

bool _optBool(Map<String, dynamic> args, String key) =>
    args[key] as bool? ?? false;

/// Builds the browser tool family over [controller]. Every tool is exec-tier
/// (the [AgentTool] default) and throws [BrowserToolException] on failure.
List<AgentTool> browserTools({
  required BrowserController controller,
  required Future<String> Function(Uint8List png) saveScreenshot,
}) {
  AgentTool tool(
    String name,
    String description,
    Map<String, dynamic> parameters,
    Future<ToolExecutionResult> Function(Map<String, dynamic>) run,
  ) => AgentTool(
    name: name,
    label: name,
    description: description,
    parameters: parameters,
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      return run(arguments);
    },
  );

  final tabIdProp = {'type': 'integer', 'description': _tabPin};

  return [
    tool(
      'browser_navigate',
      'Navigates a browser tab to a URL. Returns the tab id, final URL, and '
          'page title — use the returned tabId to pin later ops. '
          '$_restrictedNote',
      {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': 'URL to navigate to'},
          'tabId': tabIdProp,
        },
        'required': ['url'],
      },
      (args) async {
        final nav = await controller.navigate(
          _reqString(args, 'url'),
          tabId: args['tabId'] as int?,
        );
        return ToolExecutionResult.text(
          'navigated tab ${nav.tabId} to ${nav.url} — ${nav.title}',
        );
      },
    ),
    tool(
      'browser_tabs',
      'Lists open tabs with id, url, title, the active one, and the tab '
          'group. Tabs this agent opened live in a labelled task group. Use '
          'a listed id as tabId to pin later ops.',
      {'type': 'object', 'properties': {}},
      (args) async {
        final tabs = await controller.listTabs();
        if (tabs.isEmpty) {
          return ToolExecutionResult.text('no tabs open');
        }
        return ToolExecutionResult.text(
          [
            for (final tab in tabs)
              'tab ${tab.id}: ${tab.title} ${tab.url}'
                  '${tab.active ? ' — ACTIVE' : ''}'
                  '${tab.groupId == null ? '' : ' — group ${tab.groupId}'}',
          ].join('\n'),
        );
      },
    ),
    tool(
      'browser_switch_tab',
      'Makes the given tab the active one (later unpinned ops use it).',
      {
        'type': 'object',
        'properties': {
          'tabId': {'type': 'integer', 'description': 'tab to activate'},
        },
        'required': ['tabId'],
      },
      (args) async {
        final tabId = _reqInt(args, 'tabId');
        await controller.switchTab(tabId);
        return ToolExecutionResult.text('switched to tab $tabId');
      },
    ),
    tool(
      'browser_click',
      'Clicks the element matching a CSS selector. Run browser_read_dom '
          'first to discover selectors. $_restrictedNote',
      {
        'type': 'object',
        'properties': {
          'selector': {
            'type': 'string',
            'description': 'CSS selector of the element to click',
          },
          'tabId': tabIdProp,
        },
        'required': ['selector'],
      },
      (args) async {
        final selector = _reqString(args, 'selector');
        await controller.click(selector, tabId: args['tabId'] as int?);
        return ToolExecutionResult.text('clicked $selector');
      },
    ),
    tool(
      'browser_type',
      'Types text into the element matching a CSS selector; submit=true '
          'presses Enter afterwards. $_restrictedNote',
      {
        'type': 'object',
        'properties': {
          'selector': {
            'type': 'string',
            'description': 'CSS selector of the input element',
          },
          'text': {'type': 'string', 'description': 'text to type'},
          'submit': {
            'type': 'boolean',
            'description': 'press Enter after typing (default false)',
          },
          'tabId': tabIdProp,
        },
        'required': ['selector', 'text'],
      },
      (args) async {
        final selector = _reqString(args, 'selector');
        final text = _reqString(args, 'text');
        final submit = _optBool(args, 'submit');
        await controller.type(
          selector,
          text,
          submit: submit,
          tabId: args['tabId'] as int?,
        );
        return ToolExecutionResult.text(
          'typed ${text.length} characters into $selector'
          '${submit ? ' and pressed Enter' : ''}',
        );
      },
    ),
    tool(
      'browser_press_key',
      'Presses a key — Enter, Tab, Escape, Backspace, Delete, ArrowDown, '
          'ArrowUp, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown — '
          'optionally focused on a CSS selector. $_restrictedNote',
      {
        'type': 'object',
        'properties': {
          'key': {
            'type': 'string',
            'description': 'key name, e.g. Enter, Tab, Escape, ArrowDown',
          },
          'selector': {
            'type': 'string',
            'description': 'CSS selector to focus first (optional)',
          },
          'tabId': tabIdProp,
        },
        'required': ['key'],
      },
      (args) async {
        final key = _reqString(args, 'key');
        await controller.pressKey(
          key,
          selector: args['selector'] as String?,
          tabId: args['tabId'] as int?,
        );
        return ToolExecutionResult.text('pressed $key');
      },
    ),
    tool(
      'browser_select',
      'Selects an option by value in the <select> matching a CSS selector. '
          '$_restrictedNote',
      {
        'type': 'object',
        'properties': {
          'selector': {
            'type': 'string',
            'description': 'CSS selector of the <select> element',
          },
          'value': {'type': 'string', 'description': 'option value to select'},
          'tabId': tabIdProp,
        },
        'required': ['selector', 'value'],
      },
      (args) async {
        final selector = _reqString(args, 'selector');
        final value = _reqString(args, 'value');
        await controller.select(selector, value, tabId: args['tabId'] as int?);
        return ToolExecutionResult.text('selected "$value" in $selector');
      },
    ),
    tool(
      'browser_read_dom',
      'Reads a bounded serialized DOM subtree where every element carries '
          'its CSS selector — call this BEFORE browser_click/browser_type '
          'to discover selectors. nodeCount/truncated tell you when to '
          'narrow with selector or maxNodes. $_restrictedNote',
      {
        'type': 'object',
        'properties': {
          'selector': {
            'type': 'string',
            'description': 'CSS selector of the subtree root (default: page)',
          },
          'maxNodes': {
            'type': 'integer',
            'description': 'node budget (default 500, max 5000)',
          },
          'includeShadow': {
            'type': 'boolean',
            'description': 'include shadow DOM (default false)',
          },
          'tabId': tabIdProp,
        },
      },
      (args) async {
        final maxNodes = args['maxNodes'] as int?;
        if (maxNodes != null && maxNodes > 5000) {
          throw BrowserToolException('bad_args', 'maxNodes must be <= 5000');
        }
        final dom = await controller.readDom(
          selector: args['selector'] as String?,
          maxNodes: maxNodes,
          includeShadow: _optBool(args, 'includeShadow'),
          tabId: args['tabId'] as int?,
        );
        return ToolExecutionResult.text(
          '${dom.dom}\n'
          '[${dom.nodeCount} nodes'
          '${dom.truncated ? ', TRUNCATED — narrow with selector '
                    'or maxNodes' : ''}]',
        );
      },
    ),
    tool(
      'browser_eval',
      'Evaluates JavaScript in the page\'s isolated world; async code is '
          'supported (a returned Promise is awaited and its resolution is '
          'the result). Prefer the dedicated browser_* tools for DOM '
          'actions. $_restrictedNote',
      {
        'type': 'object',
        'properties': {
          'code': {'type': 'string', 'description': 'JavaScript to evaluate'},
          'tabId': tabIdProp,
        },
        'required': ['code'],
      },
      (args) async {
        final result = await controller.evalCode(
          _reqString(args, 'code'),
          tabId: args['tabId'] as int?,
        );
        return ToolExecutionResult.text('eval result: ${jsonEncode(result)}');
      },
    ),
    tool(
      'browser_screenshot',
      'Captures a PNG screenshot of a tab. Returns the saved file path and '
          'the image inline. $_restrictedNote',
      {
        'type': 'object',
        'properties': {'tabId': tabIdProp},
      },
      (args) async {
        final png = await controller.screenshot(tabId: args['tabId'] as int?);
        final path = await saveScreenshot(png);
        return ToolExecutionResult(
          content: [
            TextContent(
              text: '![screenshot]($path)\nsaved screenshot to $path',
            ),
            ImageContent(data: base64Encode(png), mimeType: 'image/png'),
          ],
        );
      },
    ),
    tool(
      'browser_wait_for',
      'Waits until text appears or a CSS selector matches a tab (give one '
          'of them), up to timeoutMs — use after navigation or clicks that '
          'trigger async updates. $_restrictedNote',
      {
        'type': 'object',
        'properties': {
          'selector': {
            'type': 'string',
            'description': 'CSS selector to wait for',
          },
          'text': {'type': 'string', 'description': 'text to wait for'},
          'timeoutMs': {
            'type': 'integer',
            'description': 'give up after this long (default 10000, max 30000)',
          },
          'tabId': tabIdProp,
        },
      },
      (args) async {
        final selector = args['selector'] as String?;
        final text = args['text'] as String?;
        final timeoutMs = args['timeoutMs'] as int? ?? 10000;
        if (timeoutMs > 30000) {
          throw BrowserToolException('bad_args', 'timeoutMs must be <= 30000');
        }
        if (selector == null && text == null) {
          throw BrowserToolException(
            'bad_args',
            'one of selector or text is required',
          );
        }
        final wait = await controller.waitFor(
          selector: selector,
          text: text,
          timeoutMs: timeoutMs,
          tabId: args['tabId'] as int?,
        );
        final target = selector ?? text;
        return ToolExecutionResult.text(
          'found "$target" after ${wait.waitedMs}ms',
        );
      },
    ),
  ];
}

/// Saves a screenshot PNG under `generated/browser-<epochMs>.png` in the
/// env root — the media tools' `generated/` convention. Hosts with
/// different persistence pass their own [browserTools] saver instead.
// ponytail: epochMs name can collide when two captures land in the same
// millisecond; the media tools add a random suffix — add one if that bites.
Future<String> saveBrowserScreenshot(ExecutionEnv env, Uint8List png) async {
  const dir = 'generated';
  final created = await env.createDir(dir, recursive: true);
  if (created.isErr) {
    throw BrowserToolException('denied', 'failed to create $dir/');
  }
  final rel = '$dir/browser-${DateTime.now().millisecondsSinceEpoch}.png';
  final written = await env.writeBinaryFile(rel, png);
  if (written.isErr) {
    throw BrowserToolException('denied', 'failed to write $rel');
  }
  return rel;
}
