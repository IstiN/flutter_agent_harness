// Per-turn active-tab context for the panel agent (issue #34): before a
// user turn runs, the host asks the browser-tool surface which tab is
// focused and, when that (url, title) changed since the last injected
// line, prepends one hidden `[context] active tab:` line to the turn
// text. The line rides the user message on purpose — the system prompt
// must stay stable (prompt caching) and would go stale the moment the
// user switches tabs mid-session.
//
// Pure Dart: no chrome imports — the host feeds in a `Tab?` from the
// shared browser-api accessor, so tests exercise the whole decision table
// (inject / dedupe / change / restricted) without a browser.
library;

import 'browser_api_tools.dart' show restrictedReason;
import 'chrome_api.dart' show Tab;

/// Announced line for a tab whose tools are refused (E1/E17): the agent
/// learns the page is off-limits instead of a URL it cannot act on.
const restrictedTabContextLine =
    '[context] active tab: '
    'restricted page, tools unavailable';

/// Remembers the last (url, title) this instance announced and decides
/// whether the next turn needs a fresh line. One instance per agent
/// session — the memory is in-memory only (a service-worker restart
/// re-announces once, which is the safe direction).
final class ActiveTabContext {
  /// (url, title) of the last injected line; null = nothing injected yet.
  (String, String)? _lastInjected;

  /// The `[context] active tab:` line for [tab], or null when the turn
  /// needs no context: no active tab at all, or the same (url, title) as
  /// the last injected line. Restricted tabs (chrome://, Web Store, … —
  /// whatever [restrictedReason] refuses) announce the restricted line
  /// and still update the memory, so an unchanged restricted page is not
  /// re-announced either.
  String? lineFor(Tab? tab) {
    if (tab == null) return null; // no tab: nothing to announce
    final key = (tab.url, tab.title);
    if (_lastInjected == key) return null; // unchanged: stay silent
    _lastInjected = key;
    if (restrictedReason(tab.url) != null) return restrictedTabContextLine;
    return '[context] active tab: ${tab.title} — ${tab.url}';
  }

  /// The turn text the host should run: resolves the active tab through
  /// [probe] (the shared surface accessor) and prepends the line when
  /// [lineFor] asks for one. A failed probe is swallowed — context is
  /// best-effort and must never block a turn, so the text runs bare.
  Future<String> decorate(Future<Tab?> Function() probe, String text) async {
    final Tab? tab;
    try {
      tab = await probe();
    } on Object {
      return text; // probe failed: run the turn without context
    }
    final line = lineFor(tab);
    return line == null ? text : '$line\n$text';
  }
}
