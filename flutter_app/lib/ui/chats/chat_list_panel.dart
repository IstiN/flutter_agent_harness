import 'dart:async';
import 'dart:ui' as ui;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/ui/network/join_sheet.dart';
import 'package:fa/ui/network/sign_in_dialog.dart';
import 'package:fa/ui/widgets/dap_hub_mark.dart';
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

/// Reference messenger conversation list shared by the wide sidebar and the
/// narrow Chats home. It owns search/keyboard affordances; section navigation
/// and the phone FAB stay in the responsive shell.
class ChatListPanel extends StatefulWidget {
  const ChatListPanel({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.onNew,
    this.compact = false,
    this.onProfile,
    this.onBrandTap,
    this.onBrandLongPress,
    this.onCollapse,
    this.headerBottom,
    this.filterActions = const <Widget>[],
    this.searchController,
    this.searchFocusNode,
    this.searchHint,
    this.onSearch,
    this.bodyBuilder,
    this.bodyKey,
    this.showCurrentDirectory = true,
    this.networkManager,
    this.networkMode,
    this.selectedEntryId,
    this.didOpen,
    this.onLocalMenu,
    this.hubBoundSessionId,
    this.expandedParents = const {},
    this.collapsedParents = const {},
    this.onToggleParent,
    this.currentDirectory,
    this.onDirectoryChanged,
  });

  final ChatListController controller;
  final Future<void> Function(ChatListEntry entry) onOpen;
  final VoidCallback onNew;
  final bool compact;
  final VoidCallback? onProfile;
  final VoidCallback? onBrandTap;
  final VoidCallback? onBrandLongPress;
  final VoidCallback? onCollapse;
  final Widget? headerBottom;

  /// Additional icon-only actions inside the filter toolbar, after the
  /// category segments and before the network selector.
  final List<Widget> filterActions;

  /// Optional shared-shell search state. Defaults retain the standalone chat
  /// list behaviour; section bodies can replace only the list below chrome.
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final String? searchHint;
  final ValueChanged<String>? onSearch;
  final Widget Function(double topPadding)? bodyBuilder;
  final Key? bodyKey;
  final bool showCurrentDirectory;
  final NetworkSessionManager? networkManager;
  final NetworkModeController? networkMode;
  final ChatEntryId? selectedEntryId;
  final bool Function(ChatListEntry entry)? didOpen;
  final Future<void> Function(ChatListEntry entry, Rect anchor)? onLocalMenu;
  final String? hubBoundSessionId;
  final Set<String> expandedParents;
  final Set<String> collapsedParents;
  final void Function(String parentId, bool expanded)? onToggleParent;

  /// Full working directory for the in-panel drill-down. The shell controls
  /// this value so it survives section switches and sidebar collapse.
  final String? currentDirectory;
  final ValueChanged<String?>? onDirectoryChanged;

  @override
  State<ChatListPanel> createState() => _ChatListPanelState();
}

class _ChatListPanelState extends State<ChatListPanel> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'chat-list-search');
  final ScrollController _scrollController = ScrollController();
  bool _hasScrollUnder = false;
  String? _localDirectory;
  ChatListFilter? _renderedFilter;

  String? get _currentDirectory {
    if (!widget.showCurrentDirectory) return null;
    return widget.onDirectoryChanged == null
        ? _localDirectory
        : widget.currentDirectory;
  }

  TextEditingController get _effectiveSearchController =>
      widget.searchController ?? _searchController;

  FocusNode get _effectiveSearchFocusNode =>
      widget.searchFocusNode ?? _searchFocus;

  void _setDirectory(String? path) {
    if (widget.onDirectoryChanged case final callback?) {
      callback(path);
    } else {
      setState(() => _localDirectory = path);
    }
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _scrollController.addListener(_onScrollUnderChanged);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _scrollController.removeListener(_onScrollUnderChanged);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onScrollUnderChanged() {
    final hasScrollUnder =
        _scrollController.hasClients &&
        _scrollController.positions.length == 1 &&
        _scrollController.offset > 0.5;
    if (hasScrollUnder == _hasScrollUnder) return;
    setState(() => _hasScrollUnder = hasScrollUnder);
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
      _effectiveSearchFocusNode.requestFocus();
      return true;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyQ ||
        command ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed ||
        _isTyping) {
      return false;
    }
    widget.onNew();
    return true;
  }

  Future<void> _open(ChatListEntry entry) async {
    _searchFocus.unfocus();
    await widget.onOpen(entry);
    if (!mounted) return;
    if (widget.didOpen?.call(entry) ?? true) {
      await widget.controller.markOpened(entry);
    }
  }

  void _clearSearch() {
    _searchController.clear();
    widget.controller.setSearch('');
    _searchFocus.unfocus();
  }

  Color _panelColor(FahColors colors) =>
      !widget.compact &&
          FaDesignTokens.of(context).direction == FaVisualDirection.glass
      ? Colors.transparent
      : colors.panel;

  bool get _networkLoading =>
      widget.controller.networkStatus == ChatLoadState.loading &&
      widget.controller.networkFilter.kind != ChatNetworkFilterKind.my;

  double get _chromeHeight {
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final searchHeight = widget.compact
        ? (isMac ? 82.0 : 54.0)
        : (isMac ? 104.0 : 58.0);
    return searchHeight +
        (widget.headerBottom == null ? 0 : 46) +
        MessengerFilterControl.height +
        (_networkLoading ? 1 : 0) +
        (_showNetworkBanner ? 50 : 0) +
        (_currentDirectory == null ? 0 : 56);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final colors = FahColors.of(context);
        final chrome = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            ?widget.headerBottom,
            _buildFilters(colors),
            if (_networkLoading) const LinearProgressIndicator(minHeight: 1),
            if (_showNetworkBanner) _buildNetworkBanner(colors),
            if (_currentDirectory case final directory?)
              _buildCurrentDirectoryHeader(colors, directory),
          ],
        );
        return ColoredBox(
          color: _panelColor(colors),
          child: Stack(
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
                      key: ValueKey(
                        'chat-directory-${_currentDirectory ?? 'root'}',
                      ),
                      child: _buildBody(colors, topPadding: _chromeHeight),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildChromeSurface(colors, chrome),
              ),
              Positioned(
                top: _chromeHeight,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: FaMotion.duration(
                      context,
                      const Duration(milliseconds: 160),
                    ),
                    opacity: _hasScrollUnder ? 1 : 0,
                    child: _buildScrollUnderFade(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChromeSurface(FahColors colors, Widget chrome) {
    final tokens = FaDesignTokens.of(context);
    if (tokens.direction != FaVisualDirection.glass) {
      return ColoredBox(color: _panelColor(colors), child: chrome);
    }
    final filter = ui.ImageFilter.blur(
      sigmaX: tokens.glassBlur,
      sigmaY: tokens.glassBlur,
    );
    final child = ColoredBox(
      color: tokens.surface1.withValues(alpha: .78),
      child: chrome,
    );
    // A large rectangular LiquidGlass surface adds refractive highlights and
    // shadows that look like artefacts over dense conversation rows. This
    // chrome needs only frost: a clean backdrop blur + tint, with no shadow.
    return ClipRect(
      key: const ValueKey('chatListGlassChrome'),
      child: BackdropGroup.of(context) != null
          ? BackdropFilter.grouped(filter: filter, child: child)
          : BackdropFilter(filter: filter, child: child),
    );
  }

  Widget _buildScrollUnderFade() {
    final tokens = FaDesignTokens.of(context);
    final filter = ui.ImageFilter.blur(
      sigmaX: tokens.glassBlur,
      sigmaY: tokens.glassBlur,
    );
    final frost = ColoredBox(
      color: tokens.surface1.withValues(alpha: .78),
      child: const SizedBox.expand(),
    );
    return SizedBox(
      height: 24,
      child: ClipRect(
        child: ShaderMask(
          key: const ValueKey('chatListScrollUnderFade'),
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.transparent],
          ).createShader(bounds),
          child: BackdropGroup.of(context) != null
              ? BackdropFilter.grouped(filter: filter, child: frost)
              : BackdropFilter(filter: filter, child: frost),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return MessengerSectionHeader(
      title: context.l10n.wideNavChats,
      searchController: _searchController,
      searchFocusNode: _searchFocus,
      searchHint: context.l10n.wideChatsSearchHint,
      onSearch: widget.controller.setSearch,
      onProfile: widget.onProfile,
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
    return MessengerCategoryChip(
      chipKey: ValueKey('chatFilter-${value.name}'),
      icon: switch (value) {
        ChatListFilter.all => Icons.inbox_outlined,
        ChatListFilter.unread => Icons.mark_chat_unread_outlined,
        ChatListFilter.agents => Icons.people_outline_rounded,
        ChatListFilter.channels => Icons.tag_rounded,
      },
      label: label,
      selected: value == selected,
      expanded: value == selected,
      compact: true,
      iconOnly: value != selected,
      animateLabel: animateLabels,
      selectionBackground: false,
      onTap: () => widget.controller.setFilter(value),
    );
  }

  Map<String, String> get _memberships {
    final result = Map<String, String>.of(widget.controller.networkNames);
    final manager = widget.networkManager;
    if (manager != null) {
      for (final entry in manager.wallet.networks.entries) {
        result[entry.key] = entry.value.name;
      }
    }
    return result;
  }

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
      onSelected: (value) {
        if (value == 'manage') {
          unawaited(
            showChatNetworksDialog(
              context,
              manager: manager,
              networkMode: widget.networkMode,
            ),
          );
        } else if (value == 'sign-in') {
          if (manager != null) {
            unawaited(showSignInDialog(context, manager: manager));
          }
        } else if (value == 'all') {
          widget.controller.setNetworkFilter(const ChatNetworkFilter.all());
        } else if (value == 'my') {
          widget.controller.setNetworkFilter(const ChatNetworkFilter.my());
        } else if (value.startsWith('network:')) {
          widget.controller.setNetworkFilter(
            ChatNetworkFilter.network(value.substring(8)),
          );
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'all', child: Text(context.l10n.chatAllNetworks)),
        PopupMenuItem(value: 'my', child: Text(context.l10n.chatLocal)),
        for (final network in _memberships.entries)
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
      ],
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
    final directory = _currentDirectory;
    bool inCurrentDirectory(ChatListEntry entry) =>
        directory == null || _folderPath(entry) == directory;
    final visibleEntries = controller.visibleEntries.where(inCurrentDirectory);
    Widget state(Widget child) => Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: child,
    );
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
    final pinned = controller.pinnedEntries.where(inCurrentDirectory).toList();
    final recent = controller.recentEntries.where(inCurrentDirectory).toList();
    return ListView(
      key: const ValueKey('chatListScroll'),
      controller: _scrollController,
      padding: EdgeInsets.only(
        top: topPadding + 2,
        bottom: widget.compact ? 76 : 10,
      ),
      children: [
        if (pinned.isNotEmpty) ...[
          _SectionHeader(label: context.l10n.chatPinned),
          ..._treeRows(pinned),
        ],
        if (recent.isNotEmpty) ...[
          _SectionHeader(label: context.l10n.chatRecent),
          ..._treeRows(recent),
        ],
      ],
    );
  }

  List<Widget> _treeRows(List<ChatListEntry> entries) {
    final byParent = <String, List<ChatListEntry>>{};
    final ids = entries.map((entry) => entry.id.value).toSet();
    for (final entry in entries) {
      final parent = entry.parentId;
      if (parent != null && ids.contains(parent)) {
        byParent.putIfAbsent(parent, () => []).add(entry);
      }
    }
    final topLevel = [
      for (final entry in entries)
        if (entry.parentId == null || !ids.contains(entry.parentId)) entry,
    ];
    final folderGroups = <String, List<ChatListEntry>>{};
    for (final entry in topLevel) {
      final key = _folderGroupKey(entry);
      if (key != null) {
        folderGroups.putIfAbsent(key, () => []).add(entry);
      }
    }
    final searching = widget.controller.searchQuery.trim().isNotEmpty;
    final renderedFolders = <String>{};
    final rows = <Widget>[];
    for (final entry in topLevel) {
      final folderKey = _folderGroupKey(entry);
      if (folderKey == null || _currentDirectory != null) {
        rows.addAll(_entryTreeRows(entry, byParent, searching));
        continue;
      }
      if (!renderedFolders.add(folderKey)) continue;
      rows.add(
        _folderDestination(entry, folderKey, folderGroups[folderKey]!.length),
      );
    }
    return rows;
  }

  List<Widget> _entryTreeRows(
    ChatListEntry entry,
    Map<String, List<ChatListEntry>> byParent,
    bool searching,
  ) {
    final children = byParent[entry.id.value] ?? const [];
    final expanded =
        searching ||
        (widget.expandedParents.contains(entry.id.value) &&
            !widget.collapsedParents.contains(entry.id.value));
    return [
      _row(entry, childCount: children.length),
      if (expanded)
        for (final child in children) _row(child, indent: 22),
    ];
  }

  String? _folderPath(ChatListEntry entry) {
    if (entry.kind != ChatListEntryKind.localAgent) return null;
    final path = entry.folderPath ?? entry.folderName;
    if (path == null || path.isEmpty) return null;
    return path;
  }

  String? _folderGroupKey(ChatListEntry entry) {
    final path = _folderPath(entry);
    return path == null ? null : 'folder::$path';
  }

  String _directoryName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((part) => part.isNotEmpty);
    return segments.isEmpty ? path : segments.last;
  }

  Widget _folderDestination(ChatListEntry entry, String key, int count) {
    final path = _folderPath(entry)!;
    return Tooltip(
      message: path,
      child: _ConversationRow(
        materialKey: ValueKey('chatFolder-$key'),
        entry: entry,
        folderPath: compactChatFolderPath(path),
        folderTitle: entry.folderName ?? _directoryName(path),
        folderCount: count,
        selected: false,
        expanded: false,
        childCount: 0,
        indent: 0,
        compact: widget.compact,
        hubBound: false,
        onOpen: () => _setDirectory(path),
        onTogglePin: () {},
        onToggleParent: null,
        onLocalMenu: null,
      ),
    );
  }

  Widget _buildCurrentDirectoryHeader(FahColors colors, String directory) {
    return Tooltip(
      message: directory,
      child: Container(
        key: const ValueKey('chatCurrentFolder'),
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        color: _panelColor(colors),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('chatFolderBack'),
              onPressed: () => _setDirectory(null),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              iconSize: 20,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(40),
                maximumSize: const Size.square(40),
              ),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Icon(Icons.folder_outlined, size: 20, color: colors.dim),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _directoryName(directory),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    directory,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.dim, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(ChatListEntry entry, {int childCount = 0, double indent = 0}) {
    final expanded =
        widget.expandedParents.contains(entry.id.value) &&
        !widget.collapsedParents.contains(entry.id.value);
    return _ConversationRow(
      entry: entry,
      selected: entry.id == widget.selectedEntryId,
      expanded: expanded,
      childCount: childCount,
      indent: indent,
      compact: widget.compact,
      hubBound: entry.id.value == widget.hubBoundSessionId,
      onOpen: entry.isLoading ? null : () => unawaited(_open(entry)),
      onTogglePin: () => unawaited(widget.controller.togglePin(entry)),
      onToggleParent: childCount == 0
          ? null
          : () => widget.onToggleParent?.call(entry.id.value, !expanded),
      onLocalMenu: entry.kind == ChatListEntryKind.localAgent
          ? widget.onLocalMenu
          : null,
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

class _ConversationRow extends StatefulWidget {
  const _ConversationRow({
    required this.entry,
    required this.selected,
    required this.expanded,
    required this.childCount,
    required this.indent,
    required this.compact,
    required this.hubBound,
    required this.onOpen,
    required this.onTogglePin,
    required this.onToggleParent,
    required this.onLocalMenu,
    this.materialKey,
    this.folderPath,
    this.folderTitle,
    this.folderCount = 0,
  });

  final Key? materialKey;
  final String? folderPath;
  final String? folderTitle;
  final int folderCount;
  final ChatListEntry entry;
  final bool selected;
  final bool expanded;
  final int childCount;
  final double indent;
  final bool compact;
  final bool hubBound;
  final VoidCallback? onOpen;
  final VoidCallback onTogglePin;
  final VoidCallback? onToggleParent;
  final Future<void> Function(ChatListEntry entry, Rect anchor)? onLocalMenu;

  @override
  State<_ConversationRow> createState() => _ConversationRowState();
}

class _ConversationRowState extends State<_ConversationRow> {
  bool _hovering = false;
  bool _focused = false;

  bool get _showActions => widget.compact || _hovering || _focused;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final colors = FahColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final selected = widget.selected;
    final onSelection = scheme.onPrimary;
    final foreground = selected ? onSelection : colors.text;
    final subdued = selected ? onSelection.withValues(alpha: .82) : colors.dim;
    final actionColor = selected ? onSelection : colors.dim;
    final network = entry.kind == ChatListEntryKind.localAgent
        ? null
        : entry.networkName ?? entry.networkId;
    final rawPreview = entry.isStreaming
        ? '${context.l10n.chatWorking} ${entry.preview ?? ''}'.trim()
        : entry.preview?.trim();
    final previewParts = [
      if (network case final value? when value.isNotEmpty) value,
      if (rawPreview case final value? when value.isNotEmpty) value,
    ];
    final folder = widget.folderPath != null;
    final preview = folder
        ? widget.folderPath!
        : previewParts.isNotEmpty
        ? previewParts.join(' · ')
        : entry.kind == ChatListEntryKind.localAgent
        ? context.l10n.chatNoPreview
        : '';
    final unread = entry.unreadCount ?? 0;
    final trailingCount = folder && unread == 0 ? widget.folderCount : unread;

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
            key: widget.materialKey ?? ValueKey('chatRow-${entry.id}'),
            color: selected
                ? accent
                : _hovering || _focused
                ? colors.panelAlt
                : Colors.transparent,
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
                    padding: EdgeInsets.fromLTRB(10 + widget.indent, 10, 4, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _Avatar(
                          entry: entry,
                          colors: colors,
                          ringColor: selected ? accent : colors.panel,
                          folderBadge: folder,
                          labelOverride: widget.folderTitle,
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
                                            widget.folderTitle ?? entry.title,
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
                                  if (trailingCount > 0)
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
                                        color: folder && unread == 0
                                            ? colors.panelAlt
                                            : selected
                                            ? onSelection
                                            : accent,
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Text(
                                        '$trailingCount',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: folder && unread == 0
                                              ? subdued
                                              : selected
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
                        if (_showActions && !folder) ...[
                          if (widget.childCount > 0)
                            IconButton(
                              key: ValueKey('chatTreeToggle-${entry.id}'),
                              onPressed: widget.onToggleParent,
                              tooltip: widget.expanded
                                  ? context.l10n.chatCollapse
                                  : context.l10n.chatExpand,
                              icon: Icon(
                                widget.expanded
                                    ? Icons.expand_more
                                    : Icons.chevron_right,
                                size: 17,
                              ),
                              color: actionColor,
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 25,
                                minHeight: 32,
                              ),
                              padding: EdgeInsets.zero,
                            ),
                          IconButton(
                            key: ValueKey('chatPin-${entry.id}'),
                            onPressed: widget.onTogglePin,
                            tooltip: entry.pinned
                                ? context.l10n.chatUnpin
                                : context.l10n.chatPin,
                            icon: Icon(
                              entry.pinned
                                  ? Icons.push_pin
                                  : Icons.push_pin_outlined,
                              size: 15,
                            ),
                            color: entry.pinned && !selected
                                ? colors.indigo
                                : actionColor,
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 27,
                              minHeight: 32,
                            ),
                            padding: EdgeInsets.zero,
                          ),
                          if (widget.onLocalMenu != null)
                            Builder(
                              builder: (buttonContext) => IconButton(
                                key: ValueKey('chatMenu-${entry.id}'),
                                onPressed: () {
                                  final box =
                                      buttonContext.findRenderObject()
                                          as RenderBox;
                                  final origin = box.localToGlobal(Offset.zero);
                                  unawaited(
                                    widget.onLocalMenu!(
                                      entry,
                                      origin & box.size,
                                    ),
                                  );
                                },
                                tooltip: context.l10n.chatMoreActions,
                                icon: const Icon(Icons.more_horiz, size: 17),
                                color: actionColor,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 25,
                                  minHeight: 32,
                                ),
                                padding: EdgeInsets.zero,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (!selected && !_hovering && !_focused)
                    Positioned(
                      left: 62 + widget.indent,
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

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.entry,
    required this.colors,
    required this.ringColor,
    this.folderBadge = false,
    this.labelOverride,
  });

  final ChatListEntry entry;
  final FahColors colors;
  final Color ringColor;
  final bool folderBadge;
  final String? labelOverride;

  @override
  Widget build(BuildContext context) {
    final channel = entry.kind == ChatListEntryKind.networkChannel;
    final label = labelOverride != null
        ? (labelOverride!.isEmpty ? '?' : labelOverride!.characters.first)
        : channel
        ? '#'
        : (entry.avatarLabel ??
              (entry.title.isEmpty ? '?' : entry.title.characters.first));
    final avatar = Container(
      key: folderBadge
          ? ValueKey('chatFolderAvatar-${entry.id}')
          : ValueKey('chatAvatar-${entry.id}'),
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: colors.panelAlt,
        borderRadius: BorderRadius.circular(channel ? 12 : 21),
      ),
      alignment: Alignment.center,
      child: entry.avatarUrl == null
          ? Text(
              label.toUpperCase(),
              style: TextStyle(
                color: colors.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(channel ? 12 : 21),
              child: Image.network(
                entry.avatarUrl!,
                width: 42,
                height: 42,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Text(label.toUpperCase()),
              ),
            ),
    );
    if (folderBadge) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              key: ValueKey('chatFolderBadge-${entry.id}'),
              width: 17,
              height: 17,
              decoration: BoxDecoration(
                color: colors.panelAlt,
                shape: BoxShape.circle,
                border: Border.all(color: ringColor, width: 2),
              ),
              child: Icon(Icons.folder_outlined, size: 10, color: colors.dim),
            ),
          ),
        ],
      );
    }
    if (entry.presence == null && !entry.isStreaming) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: switch (entry.presence) {
                ChatPresence.offline => colors.dim,
                _ => colors.teal,
              },
              shape: BoxShape.circle,
              border: Border.all(color: ringColor, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 3),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: colors.dim,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: .65,
        ),
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
