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
    this.sessionFolder,
    this.fsRevision,
    this.onProjectMountChanged,
  });

  final ExecutionEnv env;

  /// Folder the browser opens in — the session's working directory
  /// (`service.currentSessionCwd`). Resolved by [FileBrowser]: relative
  /// paths against the env cwd, absolute ones as-is. Null keeps the
  /// listing at the env cwd.
  final String? initialPath;

  /// The session's own folder, kept alongside [initialPath]: when the
  /// env cannot open it (a host path outside the visible roots) the
  /// browser shows the session-folder access gate — the allow-access
  /// flow that switches the mount — instead of silently listing the
  /// active mount.
  final String? sessionFolder;

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
    this.topCenterline = false,
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

  /// Biases the band's circles onto the chat header's shared action
  /// centerline (the sidebar collapse toggle's center) — the wide docked
  /// surface sits right of that header; standalone routes keep the band's
  /// symmetric centering.
  final bool topCenterline;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    // Explicit onClose wins; otherwise the host's docked-panel scope (the
    // in-chat panel) carries the close, and surfaces without either (the
    // end drawer) keep no circle.
    final close = onClose ?? FaFilesPanelScope.maybeOf(context)?.closePanel;
    final realGlass = tokens.direction == FaVisualDirection.glass;
    final card = FaSurface(
      key: realGlass ? null : const ValueKey('filesAppPanelCard'),
      glass: true,
      useBackdropGroup: true,
      color: tokens.surface1,
      tintAmount: .4,
      tintOpacity: .78,
      borderRadius: BorderRadius.circular(realGlass ? 17 : 18),
      // The docked header shares y=35 with the sidebar and chat actions.
      // Only standalone routes keep the original dense inset.
      padding: EdgeInsets.fromLTRB(6, topCenterline ? 2 : 3, 6, 6),
      child: FileBrowser(
        env: presentation.env,
        initialPath: presentation.initialPath,
        topCenterline: topCenterline,
        sessionFolder: presentation.sessionFolder,
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
    );
    return ColoredBox(
      key: const ValueKey('filesAppPanel'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: realGlass
            ? DecoratedBox(
                key: const ValueKey('filesAppPanelCard'),
                decoration: BoxDecoration(
                  color: tokens.surface1,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tokens.hairline),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(17),
                    child: card,
                  ),
                ),
              )
            : card,
      ),
    );
  }
}

/// Files as a pushed full-page route (Apps → Files and the shell's
/// narrow-layout Files): the SAME [FilesAppPanel] card — one Files look
/// everywhere — with the band's close circle popping the route. Wide macOS
/// shares the docked y=35 action band; only a narrow macOS window clears the
/// 32px traffic-light strip ([faAppBar] clearance).
final class FilesAppPage extends StatelessWidget {
  const FilesAppPage({super.key, required this.presentation});

  final FilesAppPresentation presentation;

  @override
  Widget build(BuildContext context) {
    // Mirrors faAppBar's macOS clearance (wide_layout_shell owns that
    // symbol; importing it here would cycle the two libraries).
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final wideMac = isMac && MediaQuery.sizeOf(context).width >= 700;
    final trafficClearance = isMac && !wideMac ? 32.0 : 0.0;
    return Padding(
      padding: EdgeInsets.only(top: trafficClearance),
      child: FilesAppPanel(
        presentation: presentation,
        inlinePreview: false,
        // The wide route sits to the right of the traffic lights, just like
        // the docked pane: no second-row clearance, one shared y=35 band.
        // A narrow macOS window still needs the native titlebar inset.
        topCenterline: wideMac,
        onClose: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
