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
/// rounded corners — the sidebar/center chrome language) whose ONE chrome
/// band carries the Files title, the search capsule and the close circle
/// above the real file browser. The browser's own header row is hidden —
/// one band per presented pane, never a stacked double header.
final class FilesAppPanel extends StatefulWidget {
  const FilesAppPanel({super.key, required this.presentation, this.onClose});

  final FilesAppPresentation presentation;
  final VoidCallback? onClose;

  @override
  State<FilesAppPanel> createState() => _FilesAppPanelState();
}

final class _FilesAppPanelState extends State<FilesAppPanel> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
          tintAmount: .4,
          tintOpacity: .78,
          borderRadius: BorderRadius.circular(18),
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FilesChrome(
                onClose: widget.onClose,
                searchController: _searchController,
              ),
              Expanded(
                child: FileBrowser(
                  env: widget.presentation.env,
                  inlinePreview: false,
                  fsRevision: widget.presentation.fsRevision,
                  onProjectMountChanged: widget.presentation.onProjectMountChanged,
                  showHeader: false,
                  filterController: _searchController,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The panel's ONE chrome band: Files title, the search capsule
/// ([FaTextField]) and the close circle — the native twin of the JS app
/// panel's chrome. The closing hairline comes from the browser's chrome
/// stack below, so the band paints no second divider.
final class _FilesChrome extends StatelessWidget {
  const _FilesChrome({this.onClose, required this.searchController});

  final VoidCallback? onClose;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      key: const ValueKey('filesAppPanelToolbar'),
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 6),
      child: Row(
        children: [
          Icon(Icons.folder_open_outlined, size: 16, color: colors.dim),
          const SizedBox(width: 7),
          Text(
            context.l10n.filesPanelTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 32,
              child: FaTextField(
                key: const ValueKey('filesAppSearch'),
                controller: searchController,
                hintText: context.l10n.filesSearchHint,
                dense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FaHeaderCircularAction(
            child: IconButton(
              key: const ValueKey('filesAppClose'),
              icon: const Icon(Icons.close, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(40),
                maximumSize: const Size.square(40),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              tooltip: context.l10n.appsCloseTooltip,
              onPressed: onClose,
            ),
          ),
        ],
      ),
    );
  }
}
