import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart'
    show sessionTileCwdLabel, sessionTileSubtitle;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// How long typing waits before the filter re-runs — live enough to feel
/// instant, coarse enough to keep big lists smooth while typing.
const _searchDebounce = Duration(milliseconds: 150);

/// Sane cap for a pasted query (E3): long pastes stop at 100 chars.
const _queryMaxLength = 100;

/// Match rank of one session against the search query: `-1` no match,
/// `0` the display name matches, `1` only id / cwd / timestamp do — name
/// matches rank first. An empty (or blank) query matches everything at
/// rank 0. Matching is a case-insensitive substring over Unicode-aware
/// lowercased text (E5: Cyrillic folds like ASCII).
int sessionSearchRank({
  required String query,
  required String title,
  required String id,
  required String? cwd,
  required DateTime updatedAt,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 0;
  if (title.toLowerCase().contains(q)) return 0;
  final haystack = [
    id,
    sessionTileCwdLabel(cwd) ?? '',
    _timestampHaystack(updatedAt),
  ].join('\n');
  return haystack.contains(q) ? 1 : -1;
}

/// Every timestamp spelling a query can hit: the tile's subtitle text
/// ("3:22 PM", "Yesterday", "Mon", "Sep 12"), the 24h form ("15:22") and
/// the month-day form ("sep 12") even when the subtitle shows a time.
String _timestampHaystack(DateTime updated) {
  final hh = updated.hour.toString().padLeft(2, '0');
  final mm = updated.minute.toString().padLeft(2, '0');
  const months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  return '${sessionTileSubtitle(updated)} '
          '$hh:$mm '
          '${months[updated.month - 1]} ${updated.day}'
      .toLowerCase();
}

/// Filters [entries] by [query] and ranks name matches first. Order inside
/// each tier is the caller's (stable) order — the list never reshuffles
/// within a tier as the query grows. The field accessor keeps the filter
/// decoupled from any concrete row type (and from any future tree
/// grouping — the projection stays a plain filter).
List<T> rankSessionEntries<T>(
  List<T> entries,
  String query,
  ({String title, String id, String? cwd, DateTime updatedAt}) Function(T)
  fields,
) {
  final q = query.trim();
  if (q.isEmpty) return entries;
  final named = <T>[];
  final other = <T>[];
  for (final entry in entries) {
    final f = fields(entry);
    switch (sessionSearchRank(
      query: q,
      title: f.title,
      id: f.id,
      cwd: f.cwd,
      updatedAt: f.updatedAt,
    )) {
      case 0:
        named.add(entry);
      case 1:
        other.add(entry);
      // -1: no field matched — the row hides.
    }
  }
  return [...named, ...other];
}

/// The sessions search empty state (E1): what the query was, and a way to
/// leave it — never a blank void.
Widget sessionSearchEmptyState(
  BuildContext context,
  FahColors colors,
  String query,
  VoidCallback onClear,
) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.sidebarSearchNoMatches(query),
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.dim),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onClear,
            child: Text(context.l10n.sidebarRenameClear),
          ),
        ],
      ),
    ),
  );
}

/// The filter field pinned at the top of a session list (macOS sidebar and
/// the mobile drawer render the same one): magnifier icon, text field,
/// clear (✕) once non-empty. Typing filters live after a short debounce;
/// Esc clears and unfocuses. The host owns [focusNode] when it needs to
/// focus the field itself (the sidebar's Cmd/Ctrl+F).
class SessionSearchField extends StatefulWidget {
  const SessionSearchField({
    super.key,
    this.focusNode,
    this.controller,
    required this.onQueryChanged,
  });

  /// Focus node for the text field; owned by the host when provided, so
  /// keyboard shortcuts can focus the field from anywhere.
  final FocusNode? focusNode;

  /// Injected text controller when the host needs to clear the field
  /// programmatically (the empty state's Clear button). Owned by the
  /// host; otherwise the field makes its own.
  final TextEditingController? controller;

  /// Fires with the applied (debounced) query; '' once the field is
  /// cleared — the full list restores instantly (state is transient).
  final ValueChanged<String> onQueryChanged;

  @override
  State<SessionSearchField> createState() => _SessionSearchFieldState();
}

class _SessionSearchFieldState extends State<SessionSearchField> {
  TextEditingController? _ownController;
  Timer? _debounce;
  FocusNode? _ownFocus;

  TextEditingController get _controller =>
      widget.controller ?? (_ownController ??= TextEditingController());

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
  }

  @override
  void didUpdateWidget(covariant SessionSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onTyped);
      _controller.addListener(_onTyped);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _ownFocus?.dispose();
      _ownFocus = null;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _onTyped() {
    // The clear (✕) affordance follows the text; the filter itself waits
    // for the debounce.
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(
      _searchDebounce,
      () => widget.onQueryChanged(_controller.text),
    );
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    _focus.unfocus();
    widget.onQueryChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clear},
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        maxLength: _queryMaxLength,
        buildCounter:
            (_, {required currentLength, required isFocused, maxLength}) =>
                null,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) {
          _debounce?.cancel();
          widget.onQueryChanged(_controller.text);
        },
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: context.l10n.sidebarSearchHint,
          prefixIcon: Icon(Icons.search, size: 18, color: colors.dim),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: context.l10n.sidebarSearchClearTooltip,
                  icon: const Icon(Icons.cancel, size: 16),
                  color: colors.dim,
                  onPressed: _clear,
                  visualDensity: VisualDensity.compact,
                ),
        ),
      ),
    );
  }
}
