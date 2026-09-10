import 'dart:io';

import 'package:test/test.dart';

/// Guard (issue #113): fa1.dev must mention every shipped surface — every
/// agent tool from every platform, the CLI entry points, and the
/// downloadable artifacts. `site/llms.txt` is the machine-readable full
/// list; `site/index.html` carries the human-facing copy and artifact
/// links.
///
/// When you add a tool, a host surface, or an artifact, mention it in
/// site/llms.txt (and site/index.html where user-visible) AND add its id
/// to the matching list below — this guard fails until both exist.
void main() {
  final llms = File('site/llms.txt').readAsStringSync();
  final index = File('site/index.html').readAsStringSync();
  final robots = File('site/robots.txt').readAsStringSync();
  final sitemap = File('site/sitemap.xml').readAsStringSync();

  /// Core tools registered on every platform (lib/src/tools/, lib/src/lsp/,
  /// lib/src/task/, lib/src/messaging/, lib/src/web_search/, lib/src/model_roles/).
  const coreTools = [
    'read', 'write', 'edit', 'ls', 'bash', 'bash_job', //
    'web_search', 'web_fetch', 'task', 'task_status', 'task_send', //
    'task_observe', 'task_cancel', 'lsp', //
    'memory_add', 'memory_delete', 'memory_list', 'memory_search', //
    'checkpoint', 'rewind', 'ask', 'request_secret', 'config', //
    'agent_message', 'agent_directory', 'schedule_message', 'reply', //
    'transcribe_audio', 'inspect_image', 'generate_image', 'generate_video',
  ];

  /// The 34 Chrome-extension tools (browser_ext/dart/src/browser_api_tools.dart).
  const extensionTools = [
    'tabs_open', 'tabs_close', 'tabs_update', 'tabs_query', 'tabs_move', //
    'tabs_group', 'tabs_ungroup', 'tabs_reload', 'tabs_discard', //
    'windows_open', 'windows_update', 'windows_close', 'windows_list', //
    'groups_update', 'groups_close', //
    'sessions_recent', 'sessions_restore', 'history_search', //
    'bookmarks_list', 'bookmarks_add', 'bookmarks_update', 'bookmarks_remove',
    'downloads_start', 'downloads_search', 'downloads_cancel', //
    'cookies_get', 'cookies_set', 'cookies_remove', //
    'inject_js', 'inject_css', 'cdp_eval', 'page_screenshot', //
    'app_screenshot', 'nav_wait',
  ];

  /// The 4 Settings-gated second-tier extension tools
  /// (browser_ext/dart/src/browser_api_tools.dart, BrowserToolVisibility.secondTier
  /// — registered only once the user enables them).
  const extensionSecondTierTools = [
    'browser_search',
    'top_sites',
    'reading_list',
    'page_capture',
  ];

  /// CLI browser-bridge tools (lib/src/browser/browser_tools.dart), driven
  /// through `fa serve --bridge` + `/browser connect`.
  const bridgeTools = [
    'browser_navigate', 'browser_click', 'browser_type', //
    'browser_press_key', 'browser_select', 'browser_tabs', //
    'browser_switch_tab', 'browser_read_dom', 'browser_screenshot', //
    'browser_eval', 'browser_wait_for',
  ];

  /// Outlook add-in mail tools (office_addin/dart/src/outlook_tools.dart).
  const outlookTools = [
    'outlook.read_current_item',
    'outlook.read_attachment',
    'outlook.insert_draft_body',
  ];

  bool mentionsWord(String haystack, String needle) =>
      RegExp('\\b${RegExp.escape(needle)}\\b').hasMatch(haystack);

  void expectMentioned(String haystack, List<String> names, String where) {
    for (final name in names) {
      expect(
        mentionsWord(haystack, name),
        isTrue,
        reason:
            '$where must mention tool `$name` — add it to the site '
            '(llms.txt / index.html) whenever a tool surface changes',
      );
    }
  }

  test('llms.txt lists every core agent tool', () {
    expectMentioned(llms, coreTools, 'site/llms.txt');
  });

  test('llms.txt lists every Chrome-extension tool', () {
    expectMentioned(llms, extensionTools, 'site/llms.txt');
    expect(
      llms,
      contains('34'),
      reason: 'llms.txt should state the tool count',
    );
  });

  test('llms.txt lists every second-tier extension tool', () {
    expectMentioned(llms, extensionSecondTierTools, 'site/llms.txt');
    expect(
      llms,
      contains('yolo drops that guard'),
      reason:
          'the inject_js always-prompt claim must stay qualified — yolo '
          'clears the override (agent_host.dart applyModePromptOverrides)',
    );
  });

  test('llms.txt lists every CLI browser-bridge tool', () {
    expect(llms, contains('fa serve --bridge'));
    expect(llms, contains('/browser connect'));
    expectMentioned(llms, bridgeTools, 'site/llms.txt');
  });

  test('llms.txt lists the Outlook mail tools and manifest', () {
    expectMentioned(llms, outlookTools, 'site/llms.txt');
    expect(llms, contains('https://fa1.dev/outlook/manifest.xml'));
  });

  test('llms.txt explains MCP tool naming', () {
    expect(llms, contains('mcp__<server>__<tool>'));
  });

  test('llms.txt mentions the CLI entry points', () {
    expect(llms, contains('`fah`'));
    expect(llms, contains('https://fa1.dev/install.sh'));
    expect(llms, contains('dart pub global activate flutter_agent_harness'));
  });

  test(
    'landing page links both downloadable artifacts and names the hosts',
    () {
      expect(index, contains('./extension/fa-extension.zip'));
      expect(index, contains('./outlook/manifest.xml'));
      expectMentioned(index, outlookTools, 'site/index.html');
      expect(
        index,
        contains('id="addons"'),
        reason: 'the add-ons section anchors the nav + hero links',
      );
      expect(index, contains('href="#addons"'));
    },
  );

  test('robots.txt stays open and points at the sitemap', () {
    expect(robots, contains('User-agent: *'));
    expect(robots, contains('Allow: /'));
    expect(robots, contains('Sitemap: https://fa1.dev/sitemap.xml'));
  });

  test('sitemap.xml covers the landing page', () {
    expect(sitemap, contains('<loc>https://fa1.dev/</loc>'));
  });
}
