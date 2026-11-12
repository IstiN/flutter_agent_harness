import 'dart:async';
import 'dart:math' as math;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/sign_in_dialog.dart';
import 'package:fa/ui/widgets/dap_hub_mark.dart';
import 'package:fa/ui/widgets/folder_avatar.dart';
import 'package:fa/ui/widgets/messenger_nav_rail.dart';
import 'package:fa/ui/widgets/messenger_navigation_controls.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart';
import 'package:fa/ui/widgets/subagent_mark.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'chat_list_controller.dart';
import 'chat_list_entry.dart';
import 'messenger_list_row_style.dart';

/// Compact a host cwd for display without changing the absolute path used as
/// the folder identity. Only a path-segment-boundary home prefix is shortened.
String compactChatFolderPath(String path, {String? homePath}) {
  final rawHome = homePath ?? desktopHomeDir();
  if (rawHome == null || rawHome.isEmpty) return path;
  final isRoot =
      rawHome == '/' || RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(rawHome);
  final home = isRoot ? rawHome : rawHome.replaceFirst(RegExp(r'[\\/]+$'), '');
  if (path == home) return '~';
  if (isRoot) {
    final separator = home.substring(home.length - 1);
    return path.startsWith(home)
        ? '~$separator${path.substring(home.length)}'
        : path;
  }
  if (path.startsWith('$home/') || path.startsWith('$home\\')) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

/// True when [entry] is a subagent session whose parent chat is still in
/// the projection — those ride the badge above the composer instead of a
/// list row. Orphans (dead or unknown parent) render as plain rows.
bool _isSubagentWithLiveParent(
  Set<String> localSessionIds,
  ChatListEntry entry,
) {
  if (!entry.isSubagent) return false;
  final parentId = entry.parentId;
  return parentId != null && localSessionIds.contains(parentId);
}

/// The one parent-only flat projection shared by expanded rows and the
/// collapsed avatar rail. Orphaned subagents remain visible as plain chats.
List<ChatListEntry> _visibleConversationEntries(ChatListController controller) {
  final localSessionIds = {
    for (final entry in controller.localEntries) entry.id.value,
  };
  return [
    for (final entry in controller.visibleEntries)
      if (!_isSubagentWithLiveParent(localSessionIds, entry)) entry,
  ];
}

/// Reference messenger conversation list shared by the wide sidebar and the
/// narrow Chats home. It owns search/keyboard affordances; section navigation
/// and the phone FAB stay in the responsive shell.
class ChatListPanel extends StatefulWidget {
  const ChatListPanel({
    super.key,
    required this.controller,
    required this.onOpen,
    this.onNew,
    this.title,
    this.compact = false,
    this.onProfile,
    this.onSettings,
    this.onBrandTap,
    this.onBrandLongPress,
    this.onCollapse,
    this.headerBottom,
    this.filterActions = const <Widget>[],
    this.filterSelectedExtraIndex,
    this.filterSelectionTextLed = false,
    this.filterSelectionHighlighted = true,
    this.filterSelectedExtraHighlighted = true,
    this.onFilterSelected,
    this.searchController,
    this.searchFocusNode,
    this.searchHint,
    this.onSearch,
    this.bodyBuilder,
    this.bodyKey,
    this.showFilterToolbar = true,
    this.networkManager,
    this.iconResolver,
    this.networkMode,
    this.selectedEntryId,
    this.didOpen,
    this.onLocalMenu,
    this.hubBoundSessionId,
  });

  final ChatListController controller;
  final Future<void> Function(ChatListEntry entry) onOpen;
  final VoidCallback? onNew;

  /// Section-owned label; null keeps the ordinary Chats title.
  final String? title;
  final bool compact;
  final VoidCallback? onProfile;
  final VoidCallback? onSettings;
  final VoidCallback? onBrandTap;
  final VoidCallback? onBrandLongPress;
  final VoidCallback? onCollapse;
  final Widget? headerBottom;

  /// Additional icon-only actions inside the filter toolbar, after the
  /// category segments and before the network selector.
  final List<Widget> filterActions;

  /// The selected [filterActions] slot, if that action group carries its own
  /// selection (the wide shell's Chats/Activity/Apps destinations). It shares
  /// the toolbar's width budget with the selected category.
  final int? filterSelectedExtraIndex;

  /// Text-led selected categories: the label replaces the icon while quiet
  /// categories remain icon-only. Used by the dense shared sidebar toolbar.
  final bool filterSelectionTextLed;

  /// Whether the selected category paints the shared selection pill. The wide
  /// shell turns this off while Activity/Apps own the toolbar's selection.
  final bool filterSelectionHighlighted;

  /// Whether the selected [filterActions] slot paints an expanded segment.
  /// The wide shell keeps its implicit Chats destination quiet even though
  /// it remains the active section.
  final bool filterSelectedExtraHighlighted;

  /// Invoked after a filter category tap. The wide shell uses it to return
  /// from Activity/Apps to the Chats home: filters and section destinations
  /// are one mutually exclusive selection.
  final VoidCallback? onFilterSelected;

  /// Optional shared-shell search state. Defaults retain the standalone chat
  /// list behaviour; section bodies can replace only the list below chrome.
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final String? searchHint;
  final ValueChanged<String>? onSearch;
  final Widget Function(double topPadding)? bodyBuilder;
  final Key? bodyKey;

  /// Whether the horizontal chat-filter/network toolbar renders. The wide
  /// shell's vertical rail and phone dock own those destinations now, so
  /// both shell forms pass false. Standalone panels retain the default bar.
  final bool showFilterToolbar;
  final NetworkSessionManager? networkManager;

  /// The same mount-rebased, cached resolver used by Local folder rows.
  /// Null keeps the deterministic gradient-letter fallback (tests/web).
  final FolderIconResolver? iconResolver;
  final NetworkModeController? networkMode;
  final ChatEntryId? selectedEntryId;
  final bool Function(ChatListEntry entry)? didOpen;
  final Future<void> Function(ChatListEntry entry, Rect anchor)? onLocalMenu;
  final String? hubBoundSessionId;

  @override
  State<ChatListPanel> createState() => _ChatListPanelState();
}

class _ChatListPanelState extends State<ChatListPanel> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'chat-list-search');
  ChatListFilter? _renderedFilter;
  bool _compactSearchVisible = false;

  TextEditingController get _effectiveSearchController =>
      widget.searchController ?? _searchController;

  FocusNode get _effectiveSearchFocusNode =>
      widget.searchFocusNode ?? _searchFocus;

  /// Every compact section starts with collapsed search. An active query or
  /// focus keeps the existing field visible even when the shell rebuilds.
  bool get _collapsibleSearch => widget.compact;

  bool get _compactSearchShown =>
      _compactSearchVisible ||
      _effectiveSearchController.text.trim().isNotEmpty ||
      _effectiveSearchFocusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _effectiveSearchController.addListener(_onSearchStateChanged);
    _effectiveSearchFocusNode.addListener(_onSearchStateChanged);
  }

  @override
  void didUpdateWidget(covariant ChatListPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldController = oldWidget.searchController ?? _searchController;
    final oldFocus = oldWidget.searchFocusNode ?? _searchFocus;
    if (oldController != _effectiveSearchController) {
      oldController.removeListener(_onSearchStateChanged);
      _effectiveSearchController.addListener(_onSearchStateChanged);
    }
    if (oldFocus != _effectiveSearchFocusNode) {
      oldFocus.removeListener(_onSearchStateChanged);
      _effectiveSearchFocusNode.addListener(_onSearchStateChanged);
    }
  }

  void _onSearchStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _effectiveSearchController.removeListener(_onSearchStateChanged);
    _effectiveSearchFocusNode.removeListener(_onSearchStateChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool get _modalIsOpen => ModalRoute.of(context)?.isCurrent == false;

  bool get _isTyping {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    var typing = false;
    focusContext.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        typing = true;
        return false;
      }
      return true;
    });
    return typing || focusContext.widget is EditableText;
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || _modalIsOpen) return false;
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isMetaPressed || keyboard.isControlPressed;
    if (event.logicalKey == LogicalKeyboardKey.keyF && command) {
      _revealSearch();
      return true;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyQ ||
        command ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed ||
        _isTyping) {
      return false;
    }
    widget.onNew?.call();
    return true;
  }

  Future<void> _open(ChatListEntry entry) async {
    _effectiveSearchFocusNode.unfocus();
    await widget.onOpen(entry);
    if (!mounted) return;
    if (widget.didOpen?.call(entry) ?? true) {
      await widget.controller.markOpened(entry);
    }
  }

  void _revealSearch() {
    if (_collapsibleSearch && !_compactSearchVisible) {
      setState(() => _compactSearchVisible = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _effectiveSearchFocusNode.requestFocus();
    });
  }

  void _closeCompactSearch() {
    _clearSearch();
    if (_compactSearchVisible) {
      setState(() => _compactSearchVisible = false);
    }
  }

  void _clearSearch() {
    _effectiveSearchController.clear();
    if (widget.onSearch case final onSearch?) {
      onSearch('');
    } else {
      widget.controller.setSearch('');
    }
    _effectiveSearchFocusNode.unfocus();
  }

  Color _panelColor(FahColors colors) =>
      !widget.compact &&
          FaDesignTokens.of(context).direction == FaVisualDirection.glass
      ? Colors.transparent
      : colors.panel;

  bool get _networkLoading =>
      widget.controller.networkStatus == ChatLoadState.loading &&
      widget.controller.networkFilter.kind != ChatNetworkFilterKind.my;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final colors = FahColors.of(context);
        final glass =
            FaDesignTokens.of(context).direction == FaVisualDirection.glass;
        // The wide panel starts to the RIGHT of the native traffic lights;
        // its actions share the y=35 chrome band, with no titlebar spacer.
        // Compact panels get their native clearance from the narrow shell.
        const titlebarTop = 0.0;
        final chrome = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            ?widget.headerBottom,
            if (widget.showFilterToolbar) _buildFilters(colors),
            if (_networkLoading) const LinearProgressIndicator(minHeight: 1),
            if (_showNetworkBanner) _buildNetworkBanner(colors),
          ],
        );
        // The chrome band IS the glass: search + segment controls sit on a
        // graduated backdrop blur and rows scroll beneath the whole band.
        // The desktop scrollbar starts below the glass instead of entering
        // it. The blur only shows where content climbs behind the band.
        return ColoredBox(
          color: _panelColor(colors),
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: ClipRect(
                  child: AnimatedSwitcher(
                    duration: FaMotion.duration(
                      context,
                      const Duration(milliseconds: 200),
                    ),
                    switchInCurve: Curves.easeInOutCubic,
                    switchOutCurve: Curves.easeInOutCubic,
                    child: KeyedSubtree(
                      key: widget.bodyKey ?? const ValueKey('chatListBody'),
                      child: widget.bodyBuilder == null
                          ? _buildBody(
                              colors,
                              topPadding: _chromeHeight() + titlebarTop,
                            )
                          : _withDesktopScrollbarInsets(
                              widget.bodyBuilder!(
                                _chromeHeight() + titlebarTop,
                              ),
                              _chromeHeight() + titlebarTop,
                            ),
                    ),
                  ),
                ),
              ),
              if (glass)
                Positioned(
                  top: titlebarTop,
                  left: 0,
                  right: 0,
                  height: _chromeHeight() + 6,
                  child: const MessengerGlassUnderlay(),
                ),
              Positioned(
                top: titlebarTop,
                left: 0,
                right: 0,
                child: _buildChromeSurface(colors, chrome),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Opaque directions keep a flat chrome background. Glass uses a bare
  /// ProgressiveBlur plus the shared token frost gradient, with small side
  /// insets and rounded top corners but no top gap. Its steep falloff leaves
  /// the lower region completely sharp, so there is no seam or border bleed.
  Widget _buildChromeSurface(FahColors colors, Widget chrome) {
    if (FaDesignTokens.of(context).direction == FaVisualDirection.glass) {
      return chrome;
    }
    return ColoredBox(color: _panelColor(colors), child: chrome);
  }

  double _chromeHeight() {
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final glassFrameCompensation =
        FaDesignTokens.of(context).direction == FaVisualDirection.glass
        ? 2.0
        : 0.0;
    // Keep the scroll body under the REAL header, not the retired 30pt
    // titlebar spacer. Narrow macOS retains its 30pt native clearance.
    final searchHeight = widget.compact
        ? (isMac ? 84.0 : 54.0)
        : (isMac ? 54.0 : 58.0) - glassFrameCompensation;
    return searchHeight +
        (widget.headerBottom == null ? 0 : 46) +
        (widget.showFilterToolbar ? MessengerFilterControl.height : 0) +
        (_networkLoading ? 1 : 0) +
        (_showNetworkBanner ? 50 : 0);
  }

  Widget _buildHeader() {
    return MessengerSectionHeader(
      title: widget.title ?? context.l10n.wideNavChats,
      searchController: _effectiveSearchController,
      searchFocusNode: _effectiveSearchFocusNode,
      searchCollapsed: _collapsibleSearch && !_compactSearchShown,
      onSearchReveal: _collapsibleSearch && !_compactSearchShown
          ? _revealSearch
          : null,
      onSearchClose: _collapsibleSearch && _compactSearchShown
          ? _closeCompactSearch
          : null,
      searchHint: widget.searchHint ?? context.l10n.wideChatsSearchHint,
      onSearch: widget.onSearch ?? widget.controller.setSearch,
      onProfile: widget.onProfile,
      onSettings: widget.onSettings,
      onNew: widget.onNew,
      onBrandTap: widget.onBrandTap,
      onBrandLongPress: widget.onBrandLongPress,
      onCollapse: widget.onCollapse,
      compact: widget.compact,
    );
  }

  Widget _buildFilters(FahColors colors) {
    final filter = widget.controller.filter;
    final animateLabels = _renderedFilter != null && _renderedFilter != filter;
    _renderedFilter = filter;
    final filters = ChatListFilter.values;
    return ColoredBox(
      color: _panelColor(colors),
      child: MessengerFilterControl(
        key: const ValueKey('chatCategoryChips'),
        selectedIndex: filters.indexOf(filter),
        categories: [
          for (final value in filters)
            _filterChip(value, _filterLabel(value), filter, animateLabels),
        ],
        extraActions: widget.filterActions,
        selectedExtraIndex: widget.filterSelectedExtraIndex,
        highlightSelectedCategory: widget.filterSelectionHighlighted,
        highlightSelectedExtra: widget.filterSelectedExtraHighlighted,
        glass: true,
        trailing: _networkFilter(colors),
      ),
    );
  }

  String _filterLabel(ChatListFilter value) => switch (value) {
    ChatListFilter.all => context.l10n.chatFilterAll,
    ChatListFilter.unread => context.l10n.chatFilterUnread,
    ChatListFilter.agents => context.l10n.chatFilterAgents,
    ChatListFilter.channels => context.l10n.chatFilterChannels,
  };

  Widget _filterChip(
    ChatListFilter value,
    String label,
    ChatListFilter selected,
    bool animateLabels,
  ) {
    final selectedVisible = widget.filterSelectionHighlighted;
    final isSelected = value == selected && selectedVisible;
    return MessengerCategoryChip(
      chipKey: ValueKey('chatFilter-${value.name}'),
      icon: switch (value) {
        ChatListFilter.all => Icons.inbox_outlined,
        ChatListFilter.unread => Icons.mark_chat_unread_outlined,
        ChatListFilter.agents => Icons.people_outline_rounded,
        ChatListFilter.channels => Icons.tag_rounded,
      },
      label: label,
      selected: isSelected,
      expanded: isSelected,
      compact: true,
      iconOnly: !isSelected,
      textLed: widget.filterSelectionTextLed && isSelected,
      animateLabel: animateLabels,
      selectionBackground: false,
      onTap: () {
        widget.controller.setFilter(value);
        widget.onFilterSelected?.call();
      },
    );
  }

  Map<String, String> get _memberships => chatNetworkMemberships(
    controller: widget.controller,
    manager: widget.networkManager,
  );

  String get _networkFilterLabel {
    final selected = widget.controller.networkFilter;
    return switch (selected.kind) {
      ChatNetworkFilterKind.all => context.l10n.chatAllNetworks,
      ChatNetworkFilterKind.my => context.l10n.chatLocal,
      ChatNetworkFilterKind.network =>
        _memberships[selected.networkId] ?? selected.networkId ?? '',
    };
  }

  Widget _networkFilter(FahColors colors) {
    final manager = widget.networkManager;
    return PopupMenuButton<String>(
      key: const ValueKey('chatNetworkFilter'),
      tooltip: _networkFilterLabel,
      onSelected: (value) => unawaited(
        selectChatNetworkFilter(
          context,
          value: value,
          controller: widget.controller,
          manager: manager,
          networkMode: widget.networkMode,
        ),
      ),
      itemBuilder: (context) => chatNetworkFilterMenuItems(
        context,
        controller: widget.controller,
        manager: manager,
      ),
      child: Container(
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color:
              widget.controller.networkFilter.kind == ChatNetworkFilterKind.all
              ? Colors.transparent
              : Theme.of(context).colorScheme.primary.withValues(alpha: .12),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.public_outlined,
              size: 18,
              color:
                  widget.controller.networkFilter.kind ==
                      ChatNetworkFilterKind.all
                  ? colors.dim
                  : Theme.of(context).colorScheme.primary,
            ),
            if (widget.controller.networkFilter.kind !=
                ChatNetworkFilterKind.all)
              Positioned(
                top: 5,
                right: 5,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool get _showNetworkBanner =>
      widget.controller.networkStatus == ChatLoadState.error &&
      widget.controller.networkFilter.kind != ChatNetworkFilterKind.my;

  Widget _buildNetworkBanner(FahColors colors) {
    return SizedBox(
      height: 50,
      child: Material(
        color: colors.panelAlt,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          child: Row(
            children: [
              Icon(Icons.cloud_off_outlined, size: 16, color: colors.dim),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  context.l10n.chatNetworkUnavailable,
                  style: TextStyle(color: colors.dim, fontSize: 11),
                ),
              ),
              TextButton(
                key: const ValueKey('chatNetworkRetry'),
                onPressed: () => unawaited(widget.controller.retryNetwork()),
                child: Text(context.l10n.chatRetry),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(FahColors colors, {required double topPadding}) {
    final controller = widget.controller;
    // The All home is ONE flat active list (owner pass): active sessions
    // AND active channels, sorted by lastActivity desc — no folder
    // grouping, no pinned/recent sections, no multi-level tree. The Local
    // folder navigation lives in the Local section; Unread is the unread
    // subset of this same flat projection ([ChatListController]
    // facetEntries already applies both).
    // Subagent sessions never render as flat rows (subagent sessions
    // owner pass): the list is PARENTS ONLY, and a parent with subagent
    // sessions carries the count chip — its picker opens the chats.
    final subagentsByParent = controller.subagentsByParent;
    final visibleEntries = _visibleConversationEntries(controller);
    final rowIndexes = <String, int>{
      for (final (index, entry) in visibleEntries.indexed)
        'chatRowState-${entry.id.canonical}': index,
    };
    Widget state(Widget child) => child;
    if (controller.status == ChatLoadState.loading) {
      return state(const Center(child: CircularProgressIndicator()));
    }
    if (controller.status == ChatLoadState.error && !_showNetworkBanner) {
      return state(
        _ErrorState(
          onRetry: () => unawaited(controller.load()),
          colors: colors,
        ),
      );
    }
    if (visibleEntries.isEmpty) {
      if (_showNetworkBanner && controller.facetEntries.isEmpty) {
        return state(
          _ErrorState(
            network: true,
            onRetry: () => unawaited(controller.retryNetwork()),
            colors: colors,
          ),
        );
      }
      return state(_buildEmpty(colors));
    }
    final list = ListView.builder(
      key: const ValueKey('chatListScroll'),
      padding: EdgeInsets.only(
        top: topPadding + 2,
        // Compact (phone): the floating dock scrolls OVER this list via the
        // shell scaffold's extendBody — the inflated ambient padding.bottom
        // covers exactly the dock's occupied height, so reserving it keeps
        // the last rows reachable above the pill. The legacy 76 stays for
        // hosts whose MediaQuery was not inflated (desktop keeps 10).
        bottom: widget.compact
            ? math.max<double>(76, MessengerFloatingDockInsets.bottomOf(context))
            : 10,
      ),
      itemCount: visibleEntries.length,
      findChildIndexCallback: (key) =>
          key is ValueKey<String> ? rowIndexes[key.value] : null,
      itemBuilder: (context, index) {
        final entry = visibleEntries[index];
        if (entry.kind == ChatListEntryKind.localAgent) {
          controller.warmVisibleLocalEntry(entry.id.value);
        }
        return _row(entry, subagentsByParent);
      },
    );
    return _withDesktopScrollbarInsets(list, topPadding);
  }

  /// Material's scrollbar painter reads MediaQuery.padding. Scope the
  /// desktop-only inset to the scrolling body: its thumb starts below the
  /// glass and sits 1pt farther left, without moving or resizing the rows.
  Widget _withDesktopScrollbarInsets(Widget child, double topPadding) {
    if (widget.compact) return child;
    final query = MediaQuery.of(context);
    return MediaQuery(
      data: query.copyWith(
        padding: query.padding.copyWith(
          top: topPadding + 6,
          right: query.padding.right + 1,
        ),
      ),
      child: child,
    );
  }

  Widget _row(
    ChatListEntry entry,
    Map<String, List<ChatListEntry>> subagentsByParent,
  ) {
    final subagents = entry.kind == ChatListEntryKind.localAgent
        ? (subagentsByParent[entry.id.value] ?? const <ChatListEntry>[])
        : const <ChatListEntry>[];
    return _ConversationRow(
      key: ValueKey('chatRowState-${entry.id.canonical}'),
      entry: entry,
      selected: entry.id == widget.selectedEntryId,
      compact: widget.compact,
      hubBound: entry.id.value == widget.hubBoundSessionId,
      onOpen: entry.isLoading ? null : () => unawaited(_open(entry)),
      onTogglePin: () => unawaited(widget.controller.togglePin(entry)),
      onLocalMenu: entry.kind == ChatListEntryKind.localAgent
          ? widget.onLocalMenu
          : null,
      iconResolver: widget.iconResolver,
      networkManager: widget.networkManager,
      subagentCount: subagents.length,
    );
  }

  Widget _buildEmpty(FahColors colors) {
    final controller = widget.controller;
    if (controller.searchQuery.trim().isNotEmpty) {
      return _EmptyState(
        icon: Icons.search_off_outlined,
        title: context.l10n.chatNoSearchResults,
        actionLabel: context.l10n.chatClearSearch,
        onAction: _clearSearch,
      );
    }
    if (controller.filter != ChatListFilter.all) {
      return _EmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: switch (controller.filter) {
          ChatListFilter.unread => context.l10n.chatNoUnread,
          ChatListFilter.agents => context.l10n.chatNoAgents,
          ChatListFilter.channels => context.l10n.chatNoChannels,
          ChatListFilter.all => '',
        },
      );
    }
    if (controller.networkFilter.kind == ChatNetworkFilterKind.network) {
      return _EmptyState(
        icon: Icons.forum_outlined,
        title: context.l10n.chatNoNetworkResults,
      );
    }
    return _EmptyState(
      icon: Icons.chat_bubble_outline_rounded,
      title: context.l10n.chatNoConversationsTitle,
      body: context.l10n.chatNoConversationsBody,
      actionLabel: context.l10n.chatStartChat,
      onAction: widget.onNew,
    );
  }
}

/// Compact 96pt-sidebar content: the same chat/channel identities as the
/// expanded flat list, without titles or previews. All, Local and Networks
/// use this one rail instead of collapsing to an empty panel or old dots.
class CollapsedChatAvatarList extends StatelessWidget {
  const CollapsedChatAvatarList({
    super.key,
    required this.controller,
    required this.onOpen,
    this.selectedEntryId,
    this.iconResolver,
    this.networkManager,
    this.localOnly = false,
    this.networkOnly = false,
    this.localSessionIds,
  }) : assert(!(localOnly && networkOnly));

  final ChatListController controller;
  final Future<void> Function(ChatListEntry entry) onOpen;
  final ChatEntryId? selectedEntryId;
  final FolderIconResolver? iconResolver;
  final NetworkSessionManager? networkManager;
  final bool localOnly;
  final bool networkOnly;

  /// Optional Activity projection: only these managed local sessions stay
  /// visible, in the same order as the expanded conversation list.
  final Set<String>? localSessionIds;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = FahColors.of(context);
        final accent = Theme.of(context).colorScheme.primary;
        final entries = [
          for (final entry in _visibleConversationEntries(controller))
            if ((!localOnly || entry.kind == ChatListEntryKind.localAgent) &&
                (!networkOnly || entry.kind != ChatListEntryKind.localAgent) &&
                (localSessionIds == null ||
                    (entry.kind == ChatListEntryKind.localAgent &&
                        localSessionIds!.contains(entry.id.value))))
              entry,
        ];
        if (entries.isEmpty) return const SizedBox.shrink();
        return ListView.builder(
          key: const ValueKey('collapsedChatAvatarList'),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            if (entry.kind == ChatListEntryKind.localAgent) {
              controller.warmVisibleLocalEntry(entry.id.value);
            }
            final selected = entry.id == selectedEntryId;
            final unread = entry.unreadCount ?? 0;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Tooltip(
                message: entry.title,
                child: Semantics(
                  button: true,
                  label: entry.title,
                  selected: selected,
                  child: Material(
                    key: ValueKey('collapsedChatAvatar-${entry.id.canonical}'),
                    color: messengerListRowColor(
                      selected: selected,
                      accent: accent,
                    ),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: entry.isLoading
                          ? null
                          : () => unawaited(onOpen(entry)),
                      borderRadius: BorderRadius.circular(14),
                      child: SizedBox(
                        height: 54,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Center(
                              child: ChatListAvatar(
                                entry: entry,
                                colors: colors,
                                ringColor: selected ? accent : colors.panel,
                                iconResolver: iconResolver,
                                networkManager: networkManager,
                              ),
                            ),
                            if (unread > 0)
                              Positioned(
                                top: 1,
                                right: 1,
                                child: MessengerRailBadge(
                                  key: ValueKey(
                                    'collapsedChatUnread-${entry.id.canonical}',
                                  ),
                                  count: unread,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ConversationRow extends StatefulWidget {
  const _ConversationRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.compact,
    required this.hubBound,
    required this.onOpen,
    required this.onTogglePin,
    required this.onLocalMenu,
    required this.iconResolver,
    required this.networkManager,
    this.subagentCount = 0,
  });

  final ChatListEntry entry;
  final bool selected;
  final bool compact;
  final bool hubBound;
  final VoidCallback? onOpen;
  final VoidCallback onTogglePin;
  final Future<void> Function(ChatListEntry entry, Rect anchor)? onLocalMenu;
  final FolderIconResolver? iconResolver;
  final NetworkSessionManager? networkManager;

  /// How many subagent sessions nest under this row (parents only on the
  /// All home — zero for every other row). Informational: the chip is
  /// part of the row's own tap, which opens the PARENT chat; the actual
  /// subagent switcher lives above the chat composer.
  final int subagentCount;

  @override
  State<_ConversationRow> createState() => _ConversationRowState();
}

class _ConversationRowState extends State<_ConversationRow> {
  bool _hovering = false;
  bool _focused = false;

  bool get _showActions => widget.compact || _hovering || _focused;

  String? _networkName() {
    final entry = widget.entry;
    if (entry.kind == ChatListEntryKind.localAgent) return null;
    return entry.networkName ?? entry.networkId;
  }

  String _rawPreview(BuildContext context) {
    final entry = widget.entry;
    if (entry.isStreaming) {
      return '${context.l10n.chatWorking} ${entry.preview ?? ''}'.trim();
    }
    return entry.preview?.trim() ?? '';
  }

  String _fallbackPreview(BuildContext context) {
    if (widget.entry.kind == ChatListEntryKind.localAgent) {
      return context.l10n.chatNoPreview;
    }
    return '';
  }

  String _preview(BuildContext context) {
    final parts = [
      _networkName() ?? '',
      _rawPreview(context),
    ].where((part) => part.isNotEmpty);
    if (parts.isNotEmpty) return parts.join(' · ');
    return _fallbackPreview(context);
  }

  String _pinTooltip(BuildContext context) =>
      widget.entry.pinned ? context.l10n.chatUnpin : context.l10n.chatPin;

  IconData get _pinIcon =>
      widget.entry.pinned ? Icons.push_pin : Icons.push_pin_outlined;

  Color _pinColor(FahColors colors, Color actionColor) {
    if (widget.entry.pinned && !widget.selected) return colors.indigo;
    return actionColor;
  }

  Widget _pinButton(BuildContext context, FahColors colors, Color actionColor) {
    final entry = widget.entry;
    return IconButton(
      key: ValueKey('chatPin-${entry.id}'),
      onPressed: widget.onTogglePin,
      tooltip: _pinTooltip(context),
      icon: Icon(_pinIcon, size: 15),
      color: _pinColor(colors, actionColor),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 27, minHeight: 32),
      padding: EdgeInsets.zero,
    );
  }

  Widget _localMenuButton(BuildContext context, Color actionColor) {
    final entry = widget.entry;
    return Builder(
      builder: (buttonContext) => IconButton(
        key: ValueKey('chatMenu-${entry.id}'),
        onPressed: () {
          final box = buttonContext.findRenderObject() as RenderBox;
          final origin = box.localToGlobal(Offset.zero);
          unawaited(widget.onLocalMenu!(entry, origin & box.size));
        },
        tooltip: context.l10n.chatMoreActions,
        icon: const Icon(Icons.more_horiz, size: 17),
        color: actionColor,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 25, minHeight: 32),
        padding: EdgeInsets.zero,
      ),
    );
  }

  List<Widget> _actions(BuildContext context, Color actionColor) {
    if (!_showActions) return const [];
    return [
      _pinButton(context, FahColors.of(context), actionColor),
      if (widget.onLocalMenu != null) _localMenuButton(context, actionColor),
    ];
  }

  Color _foreground(FahColors colors, ColorScheme scheme) =>
      widget.selected ? scheme.onPrimary : colors.text;

  Color _subdued(FahColors colors, ColorScheme scheme) =>
      widget.selected ? scheme.onPrimary.withValues(alpha: .82) : colors.dim;

  Color _actionColor(FahColors colors, ColorScheme scheme) =>
      widget.selected ? scheme.onPrimary : colors.dim;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final colors = FahColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final onSelection = scheme.onPrimary;
    final selected = widget.selected;
    final foreground = _foreground(colors, scheme);
    final subdued = _subdued(colors, scheme);
    final actionColor = _actionColor(colors, scheme);
    final preview = _preview(context);
    final unread = entry.unreadCount ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Focus(
        skipTraversal: true,
        onFocusChange: (value) {
          if (mounted) setState(() => _focused = value);
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Material(
            key: ValueKey('chatRow-${entry.id}'),
            color: messengerListRowColor(selected: selected, accent: accent),
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onOpen,
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        ChatListAvatar(
                          entry: entry,
                          colors: colors,
                          ringColor: selected ? accent : colors.panel,
                          iconResolver: widget.iconResolver,
                          networkManager: widget.networkManager,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            entry.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: foreground,
                                              fontSize: 14,
                                              fontWeight: selected
                                                  ? FontWeight.w700
                                                  : FontWeight.w600,
                                              height: 1.2,
                                            ),
                                          ),
                                        ),
                                        if (entry.isSubagent) ...[
                                          const SizedBox(width: 4),
                                          SubagentMark(
                                            size: 12,
                                            color: subdued,
                                          ),
                                        ],
                                        if (widget.hubBound) ...[
                                          const SizedBox(width: 4),
                                          const DapHubMark(size: 13),
                                        ],
                                        if (entry.pinned && !_showActions) ...[
                                          const SizedBox(width: 5),
                                          Icon(
                                            Icons.push_pin,
                                            size: 11,
                                            color: subdued,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  if (widget.subagentCount > 0)
                                    _SubagentChip(
                                      count: widget.subagentCount,
                                      selected: selected,
                                    ),
                                  if (widget.subagentCount > 0)
                                    const SizedBox(width: 6),
                                  Text(
                                    chatListRelativeTime(
                                      context,
                                      entry.lastActivity,
                                    ),
                                    style: TextStyle(
                                      color: subdued,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w400,
                                      height: 1.2,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      preview,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: subdued,
                                        fontSize: 12,
                                        height: 1.25,
                                      ),
                                    ),
                                  ),
                                  if (unread > 0)
                                    Container(
                                      margin: const EdgeInsets.only(left: 6),
                                      constraints: const BoxConstraints(
                                        minWidth: 18,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: selected ? onSelection : accent,
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Text(
                                        '$unread',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: selected
                                              ? accent
                                              : onSelection,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w700,
                                          height: 1.1,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        ..._actions(context, actionColor),
                      ],
                    ),
                  ),
                  if (!selected && !_hovering && !_focused)
                    Positioned(
                      left: 62,
                      right: 12,
                      bottom: 0,
                      child: Container(
                        height: .5,
                        color: colors.border.withValues(alpha: .45),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The same identity avatar in expanded rows and the collapsed avatar rail.
class ChatListAvatar extends StatelessWidget {
  const ChatListAvatar({
    super.key,
    required this.entry,
    required this.colors,
    required this.ringColor,
    required this.iconResolver,
    required this.networkManager,
  });

  final ChatListEntry entry;
  final FahColors colors;
  final Color ringColor;
  final FolderIconResolver? iconResolver;
  final NetworkSessionManager? networkManager;

  @override
  Widget build(BuildContext context) {
    final local = entry.kind == ChatListEntryKind.localAgent;
    final channel = entry.kind == ChatListEntryKind.networkChannel;
    final running = entry.presence != null || entry.isStreaming;
    if (local || channel) {
      final folderId = entry.folderPath ?? '';
      final networkId = entry.networkId ?? '';
      final network = networkManager?.wallet.networks[networkId];
      final identity = local
          ? FutureBuilder<MemoryImage?>(
              future: iconResolver?.resolve(folderId),
              builder: (context, snapshot) => FolderAvatar(
                seed: folderId,
                label: entry.folderName ?? context.l10n.sessionFolderPersonal,
                size: 42,
                image: snapshot.data,
                circle: true,
              ),
            )
          : FolderAvatar(
              seed: networkId,
              label: network?.name ?? entry.networkName ?? networkId,
              size: 42,
              circle: true,
            );
      return SizedBox.square(
        key: ValueKey('chatAvatar-${entry.id}'),
        dimension: 42,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: identity),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                key: ValueKey(
                  channel ? 'chatAvatarChannelBadge' : 'chatAvatarFolderBadge',
                ),
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: colors.panel,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.border),
                ),
                alignment: Alignment.center,
                child: Icon(
                  channel ? Icons.tag_rounded : Icons.chat_bubble_outline,
                  size: 12,
                  color: colors.dim,
                ),
              ),
            ),
            if (running)
              // The type badge owns the bottom-right corner. Keep the same
              // running token visible at the opposite corner, unobscured.
              Positioned(
                right: -1,
                top: -1,
                child: ChatRunningDot(
                  entry: entry,
                  colors: colors,
                  ringColor: ringColor,
                ),
              ),
          ],
        ),
      );
    }

    // Network agents retain their existing direct/neutral avatar treatment.
    final Widget avatar = entry.avatarUrl == null
        ? NeutralGlyphAvatar(
            key: ValueKey('chatAvatar-${entry.id}'),
            size: 42,
            icon: Icons.chat_bubble_outline,
          )
        : ClipRRect(
            key: ValueKey('chatAvatar-${entry.id}'),
            borderRadius: BorderRadius.circular(21),
            child: Image.network(
              entry.avatarUrl!,
              width: 42,
              height: 42,
              fit: BoxFit.cover,
            ),
          );
    if (!running) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -1,
          bottom: -1,
          child: ChatRunningDot(
            entry: entry,
            colors: colors,
            ringColor: ringColor,
          ),
        ),
      ],
    );
  }
}

/// The running dot of the chat list rows — the live/streaming indicator
/// over a conversation avatar (teal; dim for offline presence, ringed by
/// the avatar's ring color). The subagent switcher above the composer
/// reuses the SAME token, so one look means "running" on every surface.
class ChatRunningDot extends StatelessWidget {
  const ChatRunningDot({
    super.key,
    required this.entry,
    required this.colors,
    this.ringColor,
    this.size = 10,
    this.borderWidth = 0,
  });

  final ChatListEntry entry;
  final FahColors colors;
  final Color? ringColor;
  final double size;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: switch (entry.presence) {
          ChatPresence.offline => colors.dim,
          _ => colors.teal,
        },
        shape: BoxShape.circle,
        border: ringColor == null || borderWidth == 0
            ? null
            : Border.all(color: ringColor!, width: borderWidth),
      ),
    );
  }
}

/// The parent row's subagent count chip (subagent sessions owner pass): a
/// compact NEUTRAL pill at the row's trailing edge — surface2 fill,
/// hairline border, ink3 branch glyph + count. Informational: the chip is
/// part of the row's own tap (which opens the PARENT chat); the actual
/// per-subagent switcher lives above the chat composer
/// ([SubagentChatSwitcher]).
class _SubagentChip extends StatelessWidget {
  const _SubagentChip({required this.count, required this.selected});

  final int count;

  /// The row's selection state — the neutral pill tints toward the
  /// selection color so it never fights the selected row's accent fill.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final onSelection = Theme.of(context).colorScheme.onPrimary;
    final ink = selected ? onSelection : tokens.ink3;
    return Container(
      key: const ValueKey('chatSubagentChip'),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: selected ? onSelection.withValues(alpha: .18) : tokens.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? onSelection.withValues(alpha: .35)
              : tokens.hairline,
          width: .5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_tree_outlined, size: 11, color: ink),
          const SizedBox(width: 3),
          Text(
            '$count',
            style: TextStyle(
              color: ink,
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: colors.dim),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.dim, fontSize: 12, height: 1.4),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.onRetry,
    required this.colors,
    this.network = false,
  });

  final VoidCallback onRetry;
  final FahColors colors;
  final bool network;

  @override
  Widget build(BuildContext context) {
    return _EmptyState(
      icon: Icons.cloud_off_outlined,
      title: network
          ? context.l10n.chatNetworkUnavailable
          : context.l10n.chatLoadError,
      actionLabel: context.l10n.chatRetry,
      onAction: onRetry,
    );
  }
}

String chatListRelativeTime(BuildContext context, DateTime? activity) {
  if (activity == null) return '';
  final difference = DateTime.now().difference(activity);
  if (difference.isNegative || difference.inMinutes < 1) {
    return context.l10n.chatTimeNow;
  }
  if (difference.inHours < 1) {
    return '${difference.inMinutes}${context.l10n.chatMinuteSuffix}';
  }
  if (difference.inHours < 24) {
    return '${difference.inHours}${context.l10n.chatHourSuffix}';
  }
  if (difference.inDays < 7) {
    return '${difference.inDays}${context.l10n.chatDaySuffix}';
  }
  return DateFormat.MMMd(
    Localizations.localeOf(context).toString(),
  ).format(activity);
}

/// Shared Network destination for the filter menu and Profile & settings.
/// Filtering never calls this flow; only an explicit manage/open action does.
Future<void> showChatNetworksDialog(
  BuildContext context, {
  required NetworkSessionManager? manager,
  NetworkModeController? networkMode,
}) async {
  if (manager == null) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: FahColors.of(dialogContext).panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: FahColors.of(dialogContext).border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: ListenableBuilder(
          listenable: manager,
          builder: (context, _) {
            final memberships = manager.wallet.networks.entries.toList();
            final colors = FahColors.of(context);
            final accountLabel =
                manager.accountDisplayName ??
                manager.accountLogin ??
                context.l10n.networkAccountFallback;
            final showAccount =
                manager.hasJwt || manager.accountDisplayName != null;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      context.l10n.networkNetworksTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (!manager.hasJwt)
                    ListTile(
                      key: const ValueKey('chatNetworksSignIn'),
                      leading: Icon(Icons.login, size: 22, color: colors.dim),
                      title: Text(context.l10n.networkSignInTitle),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      minLeadingWidth: 24,
                      onTap: () => unawaited(
                        showSignInDialog(dialogContext, manager: manager),
                      ),
                    ),
                  if (showAccount)
                    ListTile(
                      leading: Icon(
                        Icons.account_circle_outlined,
                        size: 22,
                        color: colors.teal,
                      ),
                      title: Text(
                        accountLabel,
                        key: const ValueKey('accountLabel'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: manager.sessionExpired
                          ? Text(
                              context.l10n.networkSessionExpired,
                              key: const ValueKey('sessionExpiredNote'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: colors.error),
                            )
                          : null,
                      trailing: TextButton(
                        key: const ValueKey('signOutButton'),
                        onPressed: () => unawaited(manager.signOut()),
                        child: Text(context.l10n.networkSignOut),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      minLeadingWidth: 24,
                    ),
                  if (!manager.hasJwt || showAccount)
                    Divider(
                      height: 1,
                      indent: 20,
                      endIndent: 20,
                      color: colors.border,
                    ),
                  Flexible(
                    child: memberships.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(context.l10n.chatNetworksEmpty),
                          )
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              for (final entry in memberships)
                                ListTile(
                                  leading: Icon(
                                    Icons.public,
                                    size: 22,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                  ),
                                  minLeadingWidth: 24,
                                  title: Text(entry.value.name),
                                  subtitle: Text(entry.value.memberClass),
                                  trailing: networkMode == null
                                      ? null
                                      : const Icon(Icons.chevron_right),
                                  onTap: networkMode == null
                                      ? null
                                      : () => unawaited(
                                          _openManagedNetwork(
                                            dialogContext,
                                            entry.key,
                                            manager,
                                            networkMode,
                                          ),
                                        ),
                                ),
                            ],
                          ),
                  ),
                  if (networkMode != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: OutlinedButton.icon(
                        key: const ValueKey('chatNetworksCreateJoin'),
                        onPressed: () {
                          Navigator.pop(dialogContext);
                          unawaited(
                            showJoinSheet(
                              context,
                              controller: networkMode,
                              manager: manager,
                            ),
                          );
                        },
                        icon: const Icon(Icons.add),
                        label: Text(context.l10n.chatCreateJoinNetwork),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}

Future<void> _openManagedNetwork(
  BuildContext context,
  String networkId,
  NetworkSessionManager manager,
  NetworkModeController mode,
) async {
  Navigator.pop(context);
  if (manager.wallet.networks[networkId]?.password == null) {
    await showJoinSheet(
      context,
      controller: mode,
      manager: manager,
      initialNetworkId: networkId,
    );
    return;
  }
  await mode.enterNetwork(networkId);
  try {
    await manager.resume(networkId);
  } on Object catch (error) {
    if (context.mounted) showFahErrorSnack(context, error.toString());
  }
}

/// The memberships map behind the shared network filter menu: the
/// controller's known names plus the wallet's live networks.
Map<String, String> chatNetworkMemberships({
  required ChatListController? controller,
  required NetworkSessionManager? manager,
}) {
  final result = Map<String, String>.of(controller?.networkNames ?? const {});
  if (manager != null) {
    for (final entry in manager.wallet.networks.entries) {
      result[entry.key] = entry.value.name;
    }
  }
  return result;
}

/// The identity-globe destination's menu entries, shared by the chat
/// panel's toolbar trailing (narrow) and the wide shell's rail row.
List<PopupMenuEntry<String>> chatNetworkFilterMenuItems(
  BuildContext context, {
  required ChatListController? controller,
  required NetworkSessionManager? manager,
}) {
  final memberships = chatNetworkMemberships(
    controller: controller,
    manager: manager,
  );
  return [
    PopupMenuItem(value: 'all', child: Text(context.l10n.chatAllNetworks)),
    PopupMenuItem(value: 'my', child: Text(context.l10n.chatLocal)),
    for (final network in memberships.entries)
      PopupMenuItem(
        value: 'network:${network.key}',
        child: Text(network.value),
      ),
    const PopupMenuDivider(),
    PopupMenuItem(
      value: 'manage',
      child: Text(context.l10n.chatManageNetworks),
    ),
    if (manager != null && !manager.hasJwt)
      PopupMenuItem(
        value: 'sign-in',
        child: Text(context.l10n.chatSignInNetwork),
      ),
  ];
}

/// Handles a selection from [chatNetworkFilterMenuItems]: the filter
/// values apply to the controller, the management/sign-in values open
/// their flows. Never changes the messenger home.
Future<void> selectChatNetworkFilter(
  BuildContext context, {
  required String value,
  required ChatListController controller,
  required NetworkSessionManager? manager,
  required NetworkModeController? networkMode,
}) async {
  if (value == 'manage') {
    await showChatNetworksDialog(
      context,
      manager: manager,
      networkMode: networkMode,
    );
  } else if (value == 'sign-in') {
    if (manager != null) {
      await showSignInDialog(context, manager: manager);
    }
  } else if (value == 'all') {
    controller.setNetworkFilter(const ChatNetworkFilter.all());
  } else if (value == 'my') {
    controller.setNetworkFilter(const ChatNetworkFilter.my());
  } else if (value.startsWith('network:')) {
    controller.setNetworkFilter(ChatNetworkFilter.network(value.substring(8)));
  }
}
