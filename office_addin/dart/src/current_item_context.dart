// Per-turn current-item context for the taskpane agent (issue #89 E1):
// before a user turn runs, the host probes which mailbox item is open
// and, when that item changed since the last injected line, prepends one
// hidden `[context] current item:` line to the turn text. The line rides
// the user message on purpose — the system prompt must stay stable
// (prompt caching) and would go stale the moment the user switches items
// mid-session. A stale item must never leak into a draft.
//
// Pure Dart: no Office imports beyond the facade's snapshot record — the
// host feeds in a `MailItemSnapshot?`, so tests exercise the whole
// decision table (inject / dedupe / switch / none-open) without Office.
library;

import 'office_api.dart';

/// Announced line when no item is open (the taskpane runs on a non-mail
/// view or the user closed the message): the agent learns there is
/// nothing to act on instead of a stale subject.
const currentItemNoneLine = '[context] current item: none open';

/// Remembers the last announced state (change-key = itemId) and decides
/// whether the next turn needs a fresh line. One instance per agent
/// session — the memory is in-memory only (a taskpane reload re-announces
/// once, which is the safe direction).
final class CurrentItemContext {
  /// itemId of the last injected line; null = "none open" (or nothing
  /// injected yet — both announce once, then stay silent while unchanged).
  String? _lastItemId;
  bool _announced = false;

  /// The `[context] current item:` line for [item], or null when the turn
  /// needs no context: the same item as the last injected line. A switch
  /// to another item, or to no item at all, announces the new state —
  /// once per change.
  String? lineFor(MailItemSnapshot? item) {
    final key = item?.itemId;
    if (_announced && _lastItemId == key) return null; // unchanged: silent
    _announced = true;
    _lastItemId = key;
    if (item == null) return currentItemNoneLine;
    return '[context] current item: ${item.subject} — '
        '${item.from.isEmpty ? 'unknown sender' : item.from} '
        '(${item.mode == ItemMode.compose ? 'compose draft' : 'read'})';
  }

  /// The turn text the host should run: resolves the open item through
  /// [probe] (the shared facade accessor) and prepends the line when
  /// [lineFor] asks for one. A failed probe is swallowed — context is
  /// best-effort and must never block a turn, so the text runs bare.
  Future<String> decorate(
    Future<MailItemSnapshot?> Function() probe,
    String text,
  ) async {
    final MailItemSnapshot? item;
    try {
      item = await probe();
    } on Object {
      return text; // probe failed: run the turn without context
    }
    final line = lineFor(item);
    return line == null ? text : '$line\n$text';
  }
}
