import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart'
    show sessionTileCwdLabel, sessionTileSubtitle;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// How long typing waits before the filter re-runs — live enough to feel
/// instant, coarse enough to keep big lists smooth while typing.
const _searchDebounce = Duration(milliseconds: 150);

/// The ONE search field height everywhere — chats sidebar, activity,
/// apps header and the Files band capsule: the composer-adjacent 32px
/// control row of the original sidebar search (the 32px inset), kept as
/// THE shared height after the 40pt Files capsule briefly flattened every
/// header (user call: search files was to become search chats, not the
/// other way around).
const double kSearchFieldHeight = 32.0;

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

/// The ONE search field — the kit's GlassTextField.search at
/// [kSearchFieldHeight]: magnifier icon, hint, clear (✕) once non-empty.
/// The chats sidebar, activity and apps headers and the Files band all
/// render THIS widget, so every search reads identically. Typing filters
/// live after a short debounce ([onQueryChanged]); Esc clears and
/// unfocuses. The host owns [focusNode] when it needs to focus the field
/// itself (the sidebar's Cmd/Ctrl+F).
///
/// Hosts that drive filtering from the [controller] themselves (the
/// Files band) pass no [onQueryChanged] — the field stays controlled and
/// the debounce semantics belong to the host.
class SessionSearchField extends StatefulWidget {
  const SessionSearchField({
    super.key,
    this.focusNode,
    this.controller,
    this.hintText,
    this.onQueryChanged,
  });

  /// Hint override for non-session lists reusing this field (the networks
  /// sidebar searches memberships). Defaults to "Search sessions".
  final String? hintText;

  /// Focus node for the text field; owned by the host when provided, so
  /// keyboard shortcuts can focus the field from anywhere.
  final FocusNode? focusNode;

  /// Injected text controller when the host needs to clear the field
  /// programmatically (the empty state's Clear button). Owned by the
  /// host; otherwise the field makes its own.
  final TextEditingController? controller;

  /// Fires with the applied (debounced) query; '' once the field is
  /// cleared — the full list restores instantly (state is transient).
  /// Null when the host filters from the [controller] itself.
  final ValueChanged<String>? onQueryChanged;

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
    if (widget.onQueryChanged == null) return;
    _debounce?.cancel();
    _debounce = Timer(
      _searchDebounce,
      () => widget.onQueryChanged!(_controller.text),
    );
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    _focus.unfocus();
    widget.onQueryChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final ridesGlass = tokens.direction == FaVisualDirection.glass;
    final hint = widget.hintText ?? context.l10n.sidebarSearchHint;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clear},
      child: SizedBox(
        height: kSearchFieldHeight,
        // The ONE search input is the liquid_glass_widgets kit's
        // GlassTextField.search (owner call: the input type is the kit's,
        // not our Material imitation) at OUR 32px control height. The glass
        // direction rides the kit's own glass surface with the Fa-tuned
        // settings; other directions keep an opaque recessed well
        // (surfaceStyle solid, surface2 fill) per the styleguide rule.
        // Debounce, Esc clear, the clear (✕) affordance and the 100-char
        // paste cap stay at this layer; the kit field owns focus, the
        // search action and its look.
        child: GlassTextField.search(
          key: const ValueKey('sessionSearchFieldInput'),
          controller: _controller,
          focusNode: _focus,
          height: kSearchFieldHeight,
          placeholder: hint,
          textStyle: TextStyle(color: tokens.ink1, fontSize: 13, height: 1.4),
          placeholderStyle: TextStyle(color: tokens.ink3, fontSize: 13),
          prefixIcon: Icon(Icons.search, size: 17, color: colors.dim),
          inputFormatters: [
            // The .search constructor pins maxLength; the 100-char paste
            // cap (E3) rides the formatter — same hard truncation, no
            // counter.
            LengthLimitingTextInputFormatter(_queryMaxLength),
          ],
          surfaceStyle: ridesGlass
              ? GlassSurfaceStyle.glass
              : GlassSurfaceStyle.solid,
          color: tokens.surface2,
          settings: faGlassSettings(
            tint: tokens.surface1.withValues(alpha: kFaGlassTintAlpha),
            frost: kFaGlassFrost,
          ),
          suffixIcon: _controller.text.isEmpty
              ? null
              : SizedBox.square(
                  dimension: kSearchFieldHeight,
                  child: IconButton(
                    tooltip: context.l10n.sidebarSearchClearTooltip,
                    icon: const Icon(Icons.cancel, size: 16),
                    color: colors.dim,
                    onPressed: _clear,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
          onSuffixTap: _controller.text.isEmpty ? null : _clear,
          suffixSemanticLabel: context.l10n.sidebarSearchClearTooltip,
          onSubmitted: (_) {
            _debounce?.cancel();
            widget.onQueryChanged?.call(_controller.text);
          },
        ),
      ),
    );
  }
}
