// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ExecutionEnv;

/// The native Files presentation — the parallel of
/// [MessengerAppPresentation] for non-JS content: Files opens through the
/// SAME right-pane surface flow as JS apps instead of a pushed route.
final class FilesAppPresentation {
  FilesAppPresentation({
    required this.env,
    this.fsRevision,
    this.onProjectMountChanged,
  });

  final ExecutionEnv env;
  final ValueNotifier<int>? fsRevision;
  final void Function()? onProjectMountChanged;
}

/// Files presented like an app: a floating glass card (8pt margins,
/// rounded corners — the sidebar/center chrome language) whose slim
/// capsule toolbar ([FaAdaptiveHeader]) carries the close action above
/// the real file browser.
final class FilesAppPanel extends StatelessWidget {
  const FilesAppPanel({super.key, required this.presentation, this.onClose});

  final FilesAppPresentation presentation;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
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
          borderRadius: BorderRadius.circular(18),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FilesChrome(onClose: onClose),
              const SizedBox(height: 6),
              Expanded(
                child: FileBrowser(
                  env: presentation.env,
                  inlinePreview: false,
                  fsRevision: presentation.fsRevision,
                  onProjectMountChanged: presentation.onProjectMountChanged,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The panel's capsule toolbar: a glass capsule (the sidebar chrome
/// language) hosting the styleguide adaptive header with the close
/// action — the native twin of the JS app panel's chrome.
final class _FilesChrome extends StatelessWidget {
  const _FilesChrome({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    return FaSurface(
      key: const ValueKey('filesAppPanelToolbar'),
      glass: true,
      useBackdropGroup: true,
      color: tokens.surface1,
      tintAmount: .22,
      tintOpacity: .55,
      borderRadius: BorderRadius.circular(14),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: FaAdaptiveHeader(
        key: const ValueKey('filesAppPanelHeader'),
        leading: Icon(
          Icons.folder_open_outlined,
          size: 16,
          color: colors.dim,
        ),
        title: context.l10n.filesPanelTitle,
        titleStyle: TextStyle(
          color: colors.text,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
        actions: [
          FaHeaderAction(
            key: const ValueKey('filesAppClose'),
            icon: Icons.close,
            label: context.l10n.appsCloseTooltip,
            onPressed: onClose,
            pinned: true,
          ),
        ],
        visualDensity: VisualDensity.compact,
        iconSize: 18,
      ),
    );
  }
}
