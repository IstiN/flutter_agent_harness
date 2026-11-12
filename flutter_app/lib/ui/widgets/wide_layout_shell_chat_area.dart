// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of wide_layout_shell.dart: the center chat surface — the adaptive
// chat area with its opening indicator, quick-apps header toggle, active
// chat screen and empty placeholder — lives here so the main file stays
// under the 2800-line guard. Same library, so private members resolve.

part of 'wide_layout_shell.dart';

/// The chat area family: header/opening chrome around the selected
/// transcript plus the no-session placeholder.
extension _WideLayoutShellChatArea on _WideLayoutShellState {
  // ---------------------------------------------------------------------------
  // Chat (center)
  // ---------------------------------------------------------------------------

  Widget _buildChatArea(
    FahColors colors, {
    bool narrowRoute = false,
    BuildContext? narrowChatContext,
  }) {
    final active = widget.manager.active;
    final networkEntry = _activeNetworkEntry;
    final pendingOpen = _pendingOpenId;
    if (pendingOpen != null &&
        pendingOpen != active?.id &&
        networkEntry == null &&
        (active?.service.messages.isEmpty ?? true)) {
      return _sessionOpeningIndicator(colors);
    }
    if (active == null && networkEntry == null) {
      return _buildPlaceholder(colors);
    }
    // Null (the inline wide center surface) resolves from the shell's own
    // context, exactly as before; the pushed narrow chat route passes its
    // route context so keyboard insets propagate (iOS keyboard contract).
    final chatMedia = narrowChatContext ?? context;
    return MediaQuery(
      // The ONE adaptive header (issue #225): the old session row
      // (folder + label + model chip) merged into the chat bar — the
      // shell hands the project identity + chip to the chat screen and
      // the chat renders everything in a single row above the
      // transcript. On macOS the traffic lights float over the bar, so
      // the header insets by the same top padding the session row used.
      //
      // iOS KEYBOARD CONTRACT: this override must track the AMBIENT
      // MediaQuery of where the chat actually renders. The narrow chat
      // route ([_pushNarrowChat]) builds this widget inside a pushed
      // route; resolving [MediaQuery] from the shell's own context there
      // reads the covered route below, which only re-evaluates when the
      // SHELL rebuilds — the route's copy froze viewInsets at the
      // pre-keyboard values and the chat Scaffold never resized, leaving
      // the composer buried behind the iOS keyboard. Resolving from
      // [chatMedia] (the route's own context) registers the dependency
      // on the route, so keyboard-inset changes rebuild it.
      data: MediaQuery.of(chatMedia).copyWith(
        padding: MediaQuery.paddingOf(chatMedia) + _chatAreaTopInset(narrowRoute),
      ),
      child: networkEntry != null
          ? _buildNetworkChatArea(networkEntry)
          : _buildChatScreen(colors, active!),
    );
  }

  /// With no current transcript an indicator communicates the open. When
  /// real content is already visible, keep it stable until the new loaded
  /// session activates — replacing it with a spinner reads as a flicker.
  Widget _sessionOpeningIndicator(FahColors colors) {
    return Center(
      child: SizedBox.square(
        key: const ValueKey('sessionOpeningIndicator'),
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2, color: colors.indigo),
      ),
    );
  }

  /// On macOS the traffic lights float over the bar, so the pushed narrow
  /// chat route insets the header by the same top padding the session row
  /// used.
  EdgeInsets _chatAreaTopInset(bool narrowRoute) {
    return EdgeInsets.only(top: _WideLayoutShellState._isMacOS && narrowRoute ? 28 : 0);
  }

  /// The active local session's chat screen with the wide shell's project
  /// identity, model chip and quick-apps toggle.
  Widget _buildChatScreen(FahColors colors, FlutterManagedSession active) {
    return ChatScreen(
      manager: widget.manager,
      sessionTitle: _sessionDisplayTitle(),
      inputHeader: SubagentChatBadge(
        // The subagent badge above the composer (subagent sessions
        // owner pass): one compact icon with the running count;
        // tapping it opens the anchored picker popover. Rows run
        // the SAME open flow a chat list row uses, and mark the
        // row read.
        controller: _chatController,
        sessionId: active.id,
        onOpen: _openLocalEntry,
      ),
      registry: widget.registry,
      lastConnectionStore: widget.lastConnectionStore,
      uploadPicker: widget.uploadPicker,
      asr: widget.asr,
      asrTranscriber: widget.asrTranscriber,
      audioControllerFactory: widget.audioControllerFactory,
      videoControllerFactory: widget.videoControllerFactory,
      projectIcon: Icons.folder_outlined,
      projectIconColor: _sessionHasFolder ? colors.indigo : colors.dim,
      projectLabel: _sessionFolderLabel(),
      onProjectTap: _openSessionInfoDialog,
      modelChip: QuickModelChip(
        key: const ValueKey('wideModelChip'),
        modelId: active.service.modelId,
        providerBaseUrl: active.service.activeBaseUrl,
        tooltip: context.l10n.chatModelSwitchTooltip,
        maxWidth: 240,
        onTap: () => _openModelPicker(active),
        onLongPress: () => unawaited(_openModelSettings(active.service)),
      ),
      onModelChipTap: () => _openModelPicker(active),
      chipMenuLabel: active.service.modelId,
      onAppsToggle: _quickAppsToggle(),
    );
  }

  /// The quick-apps toggle only rides the header while the vertical Duo
  /// rail is active AND apps are actually running.
  VoidCallback? _quickAppsToggle() {
    return FaDuoControlRail.isActive(context) && _runningApps.isNotEmpty
        ? () => unawaited(_showQuickApps())
        : null;
  }

  Widget _buildPlaceholder(FahColors colors) {
    return Center(
      child: Text(
        'No active session', // l10n:ignore
        style: TextStyle(color: colors.dim, fontSize: 14),
      ),
    );
  }
}
