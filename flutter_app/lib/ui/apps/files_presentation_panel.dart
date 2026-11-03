// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ExecutionEnv;

/// The native Files presentation — the parallel of
/// [MessengerAppPresentation] for non-JS content: Files opens through the
/// SAME right-pane surface flow as JS apps instead of a pushed route.
final class FilesAppPresentation {
  FilesAppPresentation({
    required this.env,
    this.initialPath,
    this.fsRevision,
    this.onProjectMountChanged,
  });

  final ExecutionEnv env;

  /// Folder the browser opens in — the session's working directory
  /// (`service.currentSessionCwd`). Resolved by [FileBrowser]: relative
  /// paths against the env cwd, absolute ones as-is. Null keeps the
  /// listing at the env cwd.
  final String? initialPath;

  final ValueNotifier<int>? fsRevision;
  final void Function()? onProjectMountChanged;
}

/// Files presented like an app: a floating glass card (8pt margins,
/// rounded corners — the sidebar/center chrome language) whose ONE chrome
/// band ([FilesChrome]) carries the Files title, the search capsule and
/// the actions above the real file browser. The browser renders the band
/// itself ([FileBrowser.showHeader]) — one band per pane, never a stacked
/// double header, and the same chrome the in-chat, drawer and pushed
/// Files surfaces use.
final class FilesAppPanel extends StatelessWidget {
  const FilesAppPanel({
    super.key,
    required this.presentation,
    this.onClose,
    this.inlinePreview = false,
  });

  final FilesAppPresentation presentation;

  /// Closes the surface through the band's close circle — the X that sits
  /// immediately LEFT of the search capsule. Null falls back to the
  /// host's [FaFilesPanelScope] (the in-chat docked panel closes through
  /// its scope, the end drawer builds without one and closes through its
  /// scrim); both null hide the circle.
  final VoidCallback? onClose;

  /// Whether file previews render inside the pane (wide docked surfaces)
  /// or push a full-screen route (narrow ones).
  final bool inlinePreview;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    // Explicit onClose wins; otherwise the host's docked-panel scope (the
    // in-chat panel) carries the close, and surfaces without either (the
    // end drawer) keep no circle.
    final close = onClose ?? FaFilesPanelScope.maybeOf(context)?.closePanel;
    return ColoredBox(
      key: const ValueKey('filesAppPanel'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: FaSurface(
          key: const ValueKey('filesAppPanelCard'),
          glass: true,
          useBackdropGroup: true,
          color: tokens.surface1,
          tintAmount: .4,
          tintOpacity: .78,
          borderRadius: BorderRadius.circular(18),
          padding: const EdgeInsets.all(6),
          child: FileBrowser(
            env: presentation.env,
            initialPath: presentation.initialPath,
            inlinePreview: inlinePreview,
            fsRevision: presentation.fsRevision,
            onProjectMountChanged: presentation.onProjectMountChanged,
            showHeader: true,
            surfaceBorder: false,
            onClose: close,
            headerKey: const ValueKey('filesAppPanelToolbar'),
            searchKey: const ValueKey('filesAppSearch'),
            closeKey: const ValueKey('filesAppClose'),
          ),
        ),
      ),
    );
  }
}

/// Files as a pushed full-page route (Apps → Files and the shell's
/// narrow-layout Files): the SAME [FilesAppPanel] card — one Files look
/// everywhere — with the band's close circle popping the route. macOS
/// traffic lights float over content, so the card clears the same 32px
/// strip the pushed app bars reserve ([faAppBar] clearance).
final class FilesAppPage extends StatelessWidget {
  const FilesAppPage({super.key, required this.presentation});

  final FilesAppPresentation presentation;

  @override
  Widget build(BuildContext context) {
    // Mirrors faAppBar's macOS clearance (wide_layout_shell owns that
    // symbol; importing it here would cycle the two libraries).
    final trafficClearance =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS ? 32.0 : 0.0;
    return Padding(
      padding: EdgeInsets.only(top: trafficClearance),
      child: FilesAppPanel(
        presentation: presentation,
        inlinePreview: false,
        onClose: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
