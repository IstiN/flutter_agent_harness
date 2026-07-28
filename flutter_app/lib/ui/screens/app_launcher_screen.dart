// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/media_player.dart';
import 'package:fa/ui/widgets/span_grid_delegate.dart';

/// iOS-home-screen-style apps launcher: the app's home on narrow layouts
/// (the wide layout keeps the classic chat home). A dynamic square grid of
/// the JS apps living in the env's `apps/` folder plus two system tiles
/// (Settings, Files); tiles reorder by drag&amp;drop, an app dropped onto
/// the CENTER of another app groups both into a folder (drop onto an edge
/// reorders, drop onto a folder adds to it), and a folder tap opens it as a
/// floating panel whose tiles launch on tap or drag out to ungroup. An app
/// whose manifest declares a `"widget"` section renders a live tile
/// ([AppTileHost]) in place of the static icon + label, spanning the
/// declared WxH grid cells (see [SpanGridDelegate]).
///
/// The layout (order, folders) persists through [LauncherLayoutStore]; the
/// apps list refreshes on the active session's [AgentService.fsRevision]
/// bumps, so apps the agent creates appear without a restart. The collapsed
/// session chat sheet (P2) floats above this grid in the same [Stack].
class AppLauncherScreen extends StatefulWidget {
  const AppLauncherScreen({
    super.key,
    required this.manager,
    this.registry,
    this.lastConnectionStore,
    this.layoutStore,
    this.appsStore,
    this.sessionNamesStore,
    this.uploadPicker,
    this.asr,
    this.asrTranscriber,
    this.audioControllerFactory,
    this.videoControllerFactory,
    this.tileEngineFactory,
  });

  /// The multi-session manager owning the active [AgentService].
  final FlutterSessionManager manager;

  /// The custom-provider registry handed to the settings screen.
  final ProviderRegistry? registry;

  /// The last-connection store handed to the settings screen.
  final LastConnectionStore? lastConnectionStore;

  /// The persisted tile layout; `null` loads it from the env (a spinner
  /// shows until then — like the sidebar's session-names store).
  final LauncherLayoutStore? layoutStore;

  /// App discovery/seeding; tests inject one with canned assets.
  final AppsStore? appsStore;

  /// The user-given session titles shown in the chat sheet header;
  /// forwarded to [SessionChatSheet].
  final SessionNamesStore? sessionNamesStore;

  /// File chooser for the chat sheet's composer; forwarded to
  /// [SessionChatSheet].
  final UploadPicker? uploadPicker;

  /// Microphone backend override for the chat sheet's composer (tests).
  final AsrApi? asr;

  /// Transcriber override for the chat sheet's composer (tests).
  final AsrTranscriber? asrTranscriber;

  /// Playback engine factory for inline audio in the chat sheet transcript.
  final SandboxAudioControllerFactory? audioControllerFactory;

  /// Playback engine factory for inline video in the chat sheet transcript.
  final SandboxVideoControllerFactory? videoControllerFactory;

  /// Test seam for live tiles: substitutes the [AppTileHost] engine so
  /// widget tests and goldens render a deterministic tile tree.
  final TileEngineFactory? tileEngineFactory;

  @override
  State<AppLauncherScreen> createState() => _AppLauncherScreenState();
}

class _AppLauncherScreenState extends State<AppLauncherScreen> {
  /// Drop x-fraction (within the target cell) that groups two apps into a
  /// folder; drops nearer an edge reorder instead.
  static const double _folderDropBand = 0.15;

  /// Size of the drag-feedback icon and the fixed drag anchor (feedback
  /// centered on the pointer) — see [_onDrop].
  static const double _feedbackSize = 64;
  static const Offset _dragAnchor = Offset(32, 32);

  LauncherLayoutStore? _layout;
  late final AppsStore _appsStore;
  List<JsAppInfo>? _apps;
  Object? _error;
  String? _openFolderId;

  Map<String, JsAppInfo> get _appsById => {
    for (final app in _apps ?? const <JsAppInfo>[]) app.id: app,
  };

  @override
  void initState() {
    super.initState();
    _appsStore = widget.appsStore ?? AppsStore(widget.manager.env);
    _layout = widget.layoutStore;
    widget.manager.addListener(_onManagerChanged);
    _attachFsRevision();
    _layout?.addListener(_onLayoutChanged);
    if (_layout == null) unawaited(_loadLayout());
    unawaited(_reloadApps());
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _detachFsRevision();
    _layout?.removeListener(_onLayoutChanged);
    super.dispose();
  }

  Future<void> _loadLayout() async {
    final store = await LauncherLayoutStore.load(widget.manager.env);
    if (!mounted || _layout != null) return;
    setState(() {
      _layout = store..addListener(_onLayoutChanged);
    });
    _syncApps();
  }

  void _onManagerChanged() {
    _attachFsRevision();
    if (mounted) setState(() {});
  }

  void _onLayoutChanged() {
    if (!mounted) return;
    // A folder dissolved under the open panel (last tile dragged out).
    final openId = _openFolderId;
    if (openId != null && _layout?.folderById(openId) == null) {
      _openFolderId = null;
    }
    setState(() {});
  }

  ValueNotifier<int>? _fsRevisionSource;

  void _attachFsRevision() {
    final source = widget.manager.active?.service.fsRevision;
    if (identical(source, _fsRevisionSource)) return;
    _fsRevisionSource?.removeListener(_reloadApps);
    _fsRevisionSource = source;
    source?.addListener(_reloadApps);
  }

  void _detachFsRevision() {
    _fsRevisionSource?.removeListener(_reloadApps);
    _fsRevisionSource = null;
  }

  Future<void> _reloadApps() async {
    try {
      await _appsStore.seedBundledApps();
      final apps = await _appsStore.listApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _error = null;
      });
      _syncApps();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  /// Reconciles the persisted layout with the discovered apps (new apps
  /// append, deleted apps vanish, empty folders dissolve).
  void _syncApps() {
    final apps = _apps;
    if (apps == null) return;
    _layout?.syncApps(apps.map((app) => app.id));
  }

  // --- drag & drop ---------------------------------------------------------

  /// One drop onto the cell of [targetKey]: folder-add on folder tiles,
  /// folder-create on the center band of an app tile, reorder elsewhere
  /// (left half inserts before, right half after). [avatarTopLeft] is the
  /// drag-feedback's top-left corner (what `DragTargetDetails.offset`
  /// carries); the fixed drag anchor recovers the pointer position.
  void _onDrop(String draggedKey, String targetKey, Offset avatarTopLeft) {
    final layout = _layout;
    if (layout == null || draggedKey == targetKey) return;
    if (LauncherLayoutStore.isFolderKey(targetKey)) {
      layout.addToFolder(LauncherLayoutStore.folderIdOf(targetKey), draggedKey);
      return;
    }
    final pointer = avatarTopLeft + _dragAnchor;
    final targetBox = _tileBoxes[targetKey];
    var fx = 0.5;
    if (targetBox != null && targetBox.hasSize && targetBox.size.width > 0) {
      final local = targetBox.globalToLocal(pointer);
      fx = local.dx / targetBox.size.width;
    }
    final bothApps =
        draggedKey.startsWith('app:') && targetKey.startsWith('app:');
    if (bothApps && (fx - 0.5).abs() <= _folderDropBand) {
      final apps = _appsById;
      final nameA = apps[draggedKey.substring(4)]?.name;
      final nameB = apps[targetKey.substring(4)]?.name;
      final autoName = nameA != null && nameB != null
          ? '$nameA & $nameB'
          : context.l10n.launcherFolderDefaultName;
      layout.createFolder(draggedKey, targetKey, name: autoName);
      return;
    }
    final keys = layout.topLevelKeys;
    final from = keys.indexOf(draggedKey);
    var to = keys.indexOf(targetKey);
    if (from < 0 || to < 0) return;
    if (fx > 0.5) to += 1;
    if (from < to) to -= 1;
    layout.reorder(from, to);
  }

  // Registry of tile render boxes so [_onDrop] can translate the global
  // drop offset into a within-cell fraction.
  final Map<String, RenderBox> _tileBoxes = {};

  // --- navigation ----------------------------------------------------------

  Future<void> _launchApp(JsAppInfo app) async {
    await pushJsApp(context, manager: widget.manager, app: app);
  }

  Future<void> _openSettings() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          service: service,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
        ),
      ),
    );
  }

  Future<void> _openFiles() async {
    final service = widget.manager.active?.service;
    if (service == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(context.l10n.chatFilesTooltip)),
          body: FileBrowser(
            env: service.env,
            inlinePreview: false,
            fsRevision: service.fsRevision,
            onProjectMountChanged: service.refreshProjectMountPrompt,
          ),
        ),
      ),
    );
  }

  // --- folder panel --------------------------------------------------------

  void _openFolder(String folderId) => setState(() => _openFolderId = folderId);

  void _closeFolder() => setState(() => _openFolderId = null);

  Future<void> _renameFolder(LauncherFolder folder) async {
    final controller = TextEditingController(text: folder.name);
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.launcherRenameFolderTooltip),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: dialogContext.l10n.launcherFolderNameHint,
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(dialogContext.l10n.settingsSaveButton),
          ),
        ],
      ),
    );
    if (saved != null) _layout?.renameFolder(folder.id, saved);
  }

  void _dissolveFolder(LauncherFolder folder) {
    _layout?.dissolveFolder(folder.id);
    _closeFolder();
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Scaffold(
      // Bottom false: the stack reaches the screen's bottom edge so the
      // floating mini chat bar hovers over the GRID (not over an empty
      // scaffold-colored band) and the expanded sheet docks edge-to-edge;
      // the grid keeps its own bottom clearance below.
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            _buildGridArea(colors),
            // The collapsed session chat (Fa button / streaming work bar)
            // and, expanded, the 92% session sheet with the pager.
            SessionChatSheet(
              manager: widget.manager,
              registry: widget.registry,
              lastConnectionStore: widget.lastConnectionStore,
              sessionNamesStore: widget.sessionNamesStore,
              uploadPicker: widget.uploadPicker,
              asr: widget.asr,
              asrTranscriber: widget.asrTranscriber,
              audioControllerFactory: widget.audioControllerFactory,
              videoControllerFactory: widget.videoControllerFactory,
            ),
            if (_openFolderId != null) ...[
              _buildFolderBarrier(colors),
              _buildFolderPanel(colors),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGridArea(FahColors colors) {
    final error = _error;
    if (error != null) {
      return Center(child: Text(context.l10n.appsLoadError('$error')));
    }
    final layout = _layout;
    if (_apps == null || layout == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              const FaMark(size: 28),
              const SizedBox(width: 10),
              Text(
                context.l10n.appsGridTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Same column count the old maxCrossAxisExtent: 120 delegate
              // produced (crossAxisExtent = width minus the padding below).
              final crossAxisCount = ((constraints.maxWidth - 32) / 120)
                  .ceil()
                  .clamp(1, 100);
              final keys = layout.topLevelKeys;
              return GridView.builder(
                // Bottom clearance for the floating mini chat bar (bar
                // height + its margin above the home indicator).
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  MediaQuery.viewPaddingOf(context).bottom + 128,
                ),
                gridDelegate: SpanGridDelegate(
                  crossAxisCount: crossAxisCount,
                  spans: [
                    for (final key in keys) _tileSpan(key, crossAxisCount),
                  ],
                ),
                itemCount: keys.length,
                itemBuilder: (context, index) =>
                    _buildCell(colors, keys[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  /// The grid span of one tile: apps with a live tile get their declared
  /// WxH (width clamped to the column count), everything else is 1x1.
  TileSpan _tileSpan(String key, int crossAxisCount) {
    if (key.startsWith('app:')) {
      final tile = _appsById[key.substring(4)]?.tileWidget;
      if (tile != null) {
        return (
          w: tile.widthCells.clamp(1, crossAxisCount),
          h: tile.heightCells,
        );
      }
    }
    return (w: 1, h: 1);
  }

  Widget _buildCell(FahColors colors, String key) {
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final box = context.findRenderObject();
          if (box is RenderBox && mounted) _tileBoxes[key] = box;
        });
        return DragTarget<String>(
          key: ValueKey('launcherCell:$key'),
          onWillAcceptWithDetails: (details) => details.data != key,
          onAcceptWithDetails: (details) =>
              _onDrop(details.data, key, details.offset),
          builder: (context, candidateData, rejectedData) {
            final highlighted = candidateData.isNotEmpty;
            return LongPressDraggable<String>(
              data: key,
              dragAnchorStrategy: (draggable, context, position) => _dragAnchor,
              feedback: Material(
                color: Colors.transparent,
                child: Opacity(
                  opacity: 0.9,
                  child: _tileIcon(colors, key, size: _feedbackSize),
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: _tileContent(colors, key),
              ),
              child: AnimatedScale(
                scale: highlighted ? 1.08 : 1,
                duration: const Duration(milliseconds: 120),
                child: _tileContent(colors, key),
              ),
            );
          },
        );
      },
    );
  }

  /// The tile body: icon square + label — or, for apps declaring a
  /// `"widget"` manifest section, the live tile ([AppTileHost]) filling the
  /// cell. Taps launch/navigate; folder taps open the folder panel.
  Widget _tileContent(FahColors colors, String key) {
    final theme = Theme.of(context);
    if (key.startsWith('app:')) {
      final app = _appsById[key.substring(4)];
      final tile = app?.tileWidget;
      if (app != null && tile != null) {
        // Live tile: the app draws its own mini UI (icon+label replaced);
        // any tap opens the full app. The cell span (WxH) comes from the
        // manifest via [_tileSpan]/[SpanGridDelegate].
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _onTileTap(key),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: AppTileHost(
              app: app,
              env: widget.manager.env,
              fsRevision: widget.manager.active?.service.fsRevision,
              engineFactory: widget.tileEngineFactory,
              onOpen: () => _onTileTap(key),
            ),
          ),
        );
      }
    }
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _onTileTap(key),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _tileIcon(colors, key),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              _tileLabel(key),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tileIcon(FahColors colors, String key, {double size = 56}) {
    final child = switch (key) {
      LauncherLayoutStore.settingsKey => Icon(
        Icons.settings_outlined,
        size: size * 0.5,
        color: colors.dim,
      ),
      LauncherLayoutStore.filesKey => Icon(
        Icons.folder_outlined,
        size: size * 0.5,
        color: colors.dim,
      ),
      _ when LauncherLayoutStore.isFolderKey(key) => _folderMiniIcons(
        colors,
        LauncherLayoutStore.folderIdOf(key),
        size,
      ),
      _ => Center(
        child: AppIcon(
          app: _appsById[key.substring(4)] ?? _fallbackApp(key),
          env: widget.manager.env,
          size: size * 0.55,
        ),
      ),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.panelAlt,
        borderRadius: BorderRadius.circular(size * 0.25),
        border: Border.all(color: colors.border),
      ),
      child: child,
    );
  }

  /// A never-persisted placeholder so a tile still renders while the app
  /// list reloads underneath it (transient — syncApps prunes stale keys).
  JsAppInfo _fallbackApp(String key) => JsAppInfo(
    id: key.substring(4),
    name: key.substring(4),
    description: '',
    icon: '📦',
    declaredPermissions: const AppPermissions(),
  );

  Widget _folderMiniIcons(FahColors colors, String folderId, double size) {
    final folder = _layout?.folderById(folderId);
    final tiles = folder?.tiles ?? const <String>[];
    final apps = _appsById;
    final shown = tiles.take(4).toList();
    return Padding(
      padding: EdgeInsets.all(size * 0.14),
      child: GridView.count(
        crossAxisCount: 2,
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        children: [
          for (final tile in shown)
            Center(
              child: AppIcon(
                app: apps[tile.substring(4)] ?? _fallbackApp(tile),
                env: widget.manager.env,
                size: size * 0.28,
              ),
            ),
        ],
      ),
    );
  }

  String _tileLabel(String key) {
    if (key == LauncherLayoutStore.settingsKey) {
      return context.l10n.settingsTitle;
    }
    if (key == LauncherLayoutStore.filesKey) {
      return context.l10n.chatFilesTooltip;
    }
    if (LauncherLayoutStore.isFolderKey(key)) {
      return _layout?.folderById(LauncherLayoutStore.folderIdOf(key))?.name ??
          context.l10n.launcherFolderDefaultName;
    }
    return _appsById[key.substring(4)]?.name ?? key.substring(4);
  }

  void _onTileTap(String key) {
    if (key == LauncherLayoutStore.settingsKey) {
      unawaited(_openSettings());
      return;
    }
    if (key == LauncherLayoutStore.filesKey) {
      unawaited(_openFiles());
      return;
    }
    if (LauncherLayoutStore.isFolderKey(key)) {
      _openFolder(LauncherLayoutStore.folderIdOf(key));
      return;
    }
    final app = _appsById[key.substring(4)];
    if (app != null) unawaited(_launchApp(app));
  }

  /// Full-screen drop surface behind the open folder panel: a tile dragged
  /// out of the folder lands here and re-enters the top-level grid. A plain
  /// tap closes the panel.
  Widget _buildFolderBarrier(FahColors colors) {
    return Positioned.fill(
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) {
          final folder = _layout?.folderById(_openFolderId ?? '');
          return folder?.tiles.contains(details.data) ?? false;
        },
        onAcceptWithDetails: (details) {
          final openId = _openFolderId;
          if (openId != null) {
            _layout?.removeFromFolder(openId, details.data);
          }
        },
        builder: (context, candidateData, rejectedData) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _closeFolder,
          child: Container(color: Colors.black.withValues(alpha: 0.45)),
        ),
      ),
    );
  }

  Widget _buildFolderPanel(FahColors colors) {
    final folder = _layout?.folderById(_openFolderId ?? '');
    if (folder == null) return const SizedBox.shrink();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320, maxHeight: 380),
        child: Material(
          key: const ValueKey('launcherFolderPanel'),
          color: colors.panelAlt,
          borderRadius: BorderRadius.circular(20),
          elevation: 12,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: context.l10n.launcherRenameFolderTooltip,
                      visualDensity: VisualDensity.compact,
                      color: colors.dim,
                      onPressed: () => unawaited(_renameFolder(folder)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder_off_outlined, size: 18),
                      tooltip: context.l10n.launcherDissolveFolder,
                      visualDensity: VisualDensity.compact,
                      color: colors.dim,
                      onPressed: () => _dissolveFolder(folder),
                    ),
                  ],
                ),
                Divider(height: 16, color: colors.border),
                Flexible(
                  child: GridView.count(
                    crossAxisCount: 3,
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    children: [
                      for (final tile in folder.tiles)
                        LongPressDraggable<String>(
                          data: tile,
                          dragAnchorStrategy: (draggable, context, position) =>
                              _dragAnchor,
                          feedback: Material(
                            color: Colors.transparent,
                            child: Opacity(
                              opacity: 0.9,
                              child: _tileIcon(
                                colors,
                                tile,
                                size: _feedbackSize,
                              ),
                            ),
                          ),
                          childWhenDragging: Opacity(
                            opacity: 0.35,
                            child: _tileContent(colors, tile),
                          ),
                          child: _tileContent(colors, tile),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
