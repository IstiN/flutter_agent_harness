part of 'wide_layout_shell.dart';

/// Shell-owned sidebar panels kept separate from navigation and chrome.
extension _WideLayoutShellPanels on _WideLayoutShellState {
  void _resizePresentation(double dx) {
    final maxWidth = math.min(720.0, MediaQuery.sizeOf(context).width * .65);
    _updateShell(() {
      // The divider is on the panel's leading edge: dragging left grows it.
      _presentationWidth = (_presentationWidth - dx)
          .clamp(300.0, maxWidth)
          .toDouble();
    });
  }

  Widget? _presentationResizeHandle(double reveal) {
    if (_appPresentation == null || reveal < 1) return null;
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: FaPaneResizeHandle(
        key: const ValueKey('wideShellPresentationResizeHandle'),
        onDragUpdate: _resizePresentation,
      ),
    );
  }

  /// The docked right-pane slot animates its width while the inner canvas
  /// keeps one size per frame, so the JS app does not reflow during reveal.
  Widget _buildDockedPresentationSlot(double reveal) {
    final width = _presentationWidth;
    return SizedBox(
      key: const ValueKey('wideShellPresentationSlot'),
      width: width * reveal,
      child: Stack(
        children: [
          ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerRight,
              minWidth: width,
              maxWidth: width,
              child: SizedBox(
                width: width,
                child: IgnorePointer(
                  ignoring: reveal < .02,
                  child: Opacity(
                    opacity: reveal,
                    child: Transform.translate(
                      offset: Offset(32 * (1 - reveal), 0),
                      child: _buildPresentedSurface(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          ?_presentationResizeHandle(reveal),
        ],
      ),
    );
  }

  /// The tighter-width overlay slides from the right and resizes from its
  /// leading edge without changing the window's other panels.
  Widget _buildFloatingPresentationSlot(double reveal) {
    final width = _presentationWidth;
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      width: width,
      child: IgnorePointer(
        ignoring: reveal < .02,
        child: Opacity(
          opacity: reveal,
          child: Transform.translate(
            offset: Offset(width * (1 - reveal), 0),
            child: Stack(
              children: [
                Positioned.fill(child: _buildPresentedSurface()),
                ?_presentationResizeHandle(reveal),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChatPanel({bool compact = false, bool collapsed = false}) {
    final dapStore = DapBindingStore.instance;
    return ListenableBuilder(
      listenable: _chatController,
      builder: (context, _) => ListenableBuilder(
        listenable: dapStore,
        builder: (context, _) => _chatPanel(
          dapBound: dapStore.boundSessionId != null,
          compact: compact,
          collapsed: collapsed,
        ),
      ),
    );
  }

  Widget _chatPanel({
    required bool dapBound,
    required bool compact,
    required bool collapsed,
  }) {
    return ChatListPanel(
      controller: _chatController,
      title: switch (_section) {
        _WideShellSection.activity => context.l10n.wideNavActivity,
        _WideShellSection.apps => context.l10n.appsGridTitle,
        _ => null,
      },
      compact: compact,
      selectedEntryId:
          _activeNetworkEntry?.id ??
          (_selectedSessionId == null
              ? null
              : ChatEntryId.local(_selectedSessionId!)),
      didOpen: (entry) =>
          entry.kind == ChatListEntryKind.localAgent &&
          widget.manager.active?.id == entry.id.value,
      hubBoundSessionId: dapBound
          ? DapBindingStore.instance.boundSessionId
          : null,
      networkManager: widget.networkSessions,
      iconResolver: _folderIcons,
      networkMode: widget.networkMode,
      onOpen: _openChatEntry,
      onNew: _newSession,
      onProfile: _openNarrowProfile,
      onBrandTap: compact ? () => unawaited(_pushNarrowChat()) : null,
      onBrandLongPress: () => unawaited(_mintSessionFromBrand()),
      onCollapse: () => _updateShell(() => _sidebarCollapsed = true),
      onLocalMenu: _showChatEntryMenu,
      headerBottom: null,
      // The rail and narrow dock own the section/filter destinations. Only
      // the rail-independent collapsed desktop sidebar retains its toolbar.
      showFilterToolbar: collapsed,
      searchController: switch (_section) {
        _WideShellSection.chats => null,
        _WideShellSection.local => null,
        _WideShellSection.activity => _activitySearchController,
        _WideShellSection.apps => _appLauncherController.searchController,
        _WideShellSection.settings => null,
      },
      searchFocusNode: _section == _WideShellSection.apps
          ? _appLauncherController.searchFocusNode
          : null,
      searchHint: switch (_section) {
        _WideShellSection.chats => null,
        _WideShellSection.local => null,
        _WideShellSection.activity => context.l10n.activitySearchHint,
        _WideShellSection.apps => context.l10n.launcherSearchHint,
        _WideShellSection.settings => null,
      },
      onSearch: switch (_section) {
        _WideShellSection.chats => null,
        _WideShellSection.local => null,
        _WideShellSection.activity => _activityController.setSearch,
        _WideShellSection.apps => (_) {},
        _WideShellSection.settings => null,
      },
      bodyKey: _section == _WideShellSection.chats
          ? null
          : ValueKey('wide-sidebar-${_section.name}'),
      bodyBuilder: switch (_section) {
        _WideShellSection.chats => null,
        _WideShellSection.local => null,
        _WideShellSection.activity => _buildActivitySidebarBody,
        _WideShellSection.apps => _buildAppsSidebarBody,
        _WideShellSection.settings => null,
      },
    );
  }

  Widget _buildActivitySidebarBody(double topPadding) {
    return ActivityListPanel(
      controller: _activityController,
      compact: _isNarrow,
      topPadding: topPadding,
      onSelect: _isNarrow
          ? (_) => _updateShell(() => _narrowActivityDetailVisible = true)
          : null,
    );
  }

  Widget _buildAppsSidebarBody(double topPadding) {
    return ListenableBuilder(
      listenable: _appLauncherController,
      builder: (context, _) => AppsDirectoryPanel(
        controller: _appLauncherController,
        appsStore: _appsStore,
        runningApps: [
          for (final presentation in _runningApps) presentation.app,
        ],
        activeAppId: _appPresentation?.app.id,
        env: widget.manager.env,
        showSearch: false,
        topPadding: topPadding,
        onOpenRunning: (app) => unawaited(_activateRunningApp(app.id)),
      ),
    );
  }

  Widget _buildCollapsedSidebarBody() {
    if (_section == _WideShellSection.settings) {
      return _buildSettingsPanel(collapsed: true);
    }
    if (_section == _WideShellSection.activity) {
      // The avatar rail is the useful collapsed destination even when the
      // Running/Recent filter is momentarily empty. Expanded Activity keeps
      // its strict filter; collapsed Activity keeps local agents reachable.
      return ListenableBuilder(
        listenable: _activityController,
        builder: (context, _) => _collapsedAvatarRail(),
      );
    }
    if (_section == _WideShellSection.apps) {
      return _buildCollapsedAppsBody();
    }
    return _collapsedAvatarRail();
  }

  Widget _buildCollapsedAppsBody() {
    return CollapsedAppsDirectory(
      controller: _appLauncherController,
      runningApps: [for (final presentation in _runningApps) presentation.app],
      activeAppId: _appPresentation?.app.id,
      env: widget.manager.env,
      onOpenRunning: (app) => unawaited(_activateRunningApp(app.id)),
    );
  }

  Widget _collapsedAvatarRail({Set<String>? localSessionIds}) {
    return SizedBox(
      key: const ValueKey('collapsedChatAvatarRail'),
      width: double.infinity,
      child: CollapsedChatAvatarList(
        controller: _chatController,
        selectedEntryId:
            _activeNetworkEntry?.id ??
            (_selectedSessionId == null
                ? null
                : ChatEntryId.local(_selectedSessionId!)),
        networkManager: widget.networkSessions,
        iconResolver: _folderIcons,
        localOnly: _section == _WideShellSection.local,
        networkOnly:
            _section == _WideShellSection.chats && _networksSurfaceOpen,
        localSessionIds: localSessionIds,
        onOpen: _openCollapsedChatEntry,
      ),
    );
  }

  /// The Local section's sidebar: folder-first navigation (folders, then a
  /// folder's Telegram-style session list), shell-owned drill-down state.
  Widget _buildLocalPanel({bool compact = false}) {
    return LocalSessionsPanel(
      controller: _chatController,
      compact: compact,
      selectedFolderId: _localFolderId,
      onSelectFolder: (folderId) =>
          _updateShell(() => _localFolderId = folderId),
      selectedSessionId: _selectedSessionId,
      onOpenSession: (entry) => unawaited(_openLocalEntry(entry)),
      onNew: _newSession,
      onCollapse: compact
          ? null
          : () => _updateShell(() => _sidebarCollapsed = true),
      iconResolver: _folderIcons,
    );
  }
}
