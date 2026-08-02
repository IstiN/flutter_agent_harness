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
  /// Size of the drag-feedback icon for classic app tiles (widget tiles
  /// drag a full-size card replica instead — see [_tileFeedback]).
  static const double _feedbackSize = 64;

  /// The pointer's grab point inside the dragged tile, captured by the
  /// drag-anchor strategy at drag start: `DragTargetDetails.offset` is the
  /// feedback's top-left corner, so `offset + _grabOffset` always recovers
  /// the pointer — for a 64px icon and a 356px widget card alike.
  Offset _grabOffset = const Offset(32, 32);

  /// Pointer speed below which a cancelled drag counts as
  /// hold-release-without-movement (the iOS "edit menu" gesture).
  static const double _holdMaxVelocity = 50;

  LauncherLayoutStore? _layout;
  late final AppsStore _appsStore;
  List<JsAppInfo>? _apps;
  Object? _error;
  String? _openFolderId;

  /// Key into the session chat sheet so the header's session chip can
  /// expand it (the chip shows WHICH session is active — the sheet hosts it).
  final _sheetKey = GlobalKey<SessionChatSheetState>();

  /// Live reorder preview while dragging: the order the grid animates to
  /// (the persisted order is only mutated on drop).
  List<String>? _previewOrder;

  /// Tile key currently highlighted as a FOLDER drop target (center-band
  /// hover on an app tile, or any hover on a folder tile); null while the
  /// drag is a reorder (or no drag).
  String? _folderHoverKey;

  /// Debounce for re-reading `launcher_layout.json` on fsRevision bumps
  /// (the agent/user may have edited grid/tileSizes/order — see §3).
  Timer? _layoutReloadDebounce;

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
    _layoutReloadDebounce?.cancel();
    _cancelFolderDwell();
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
    _fsRevisionSource?.removeListener(_onFsRevision);
    _fsRevisionSource = source;
    source?.addListener(_onFsRevision);
  }

  void _detachFsRevision() {
    _fsRevisionSource?.removeListener(_onFsRevision);
    _fsRevisionSource = null;
  }

  void _onFsRevision() {
    unawaited(_reloadApps());
    // The agent/user may also have edited launcher_layout.json (grid
    // columns, tile sizes, order) — re-read it, debounced like the tile
    // engine reloads (agent edits often write several files back to back).
    _layoutReloadDebounce?.cancel();
    _layoutReloadDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) unawaited(_layout?.reload());
    });
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

  /// Continuous hover while dragging over [targetKey]'s slot: the CENTER
  /// band of an app tile arms FOLDER intent only after a short dwell (iOS
  /// semantics — a fast pass or an edge hover means REORDER; positional
  /// alone must never steal the insert intent, big tiles cannot hit the
  /// outer sliver reliably). Any position on a folder tile arms
  /// immediately. The edge halves set a live insertion preview so the
  /// other tiles animate aside (the persisted order only changes on drop,
  /// see [_onDrop]).
  void _onDragHover(String targetKey, DragTargetDetails<String> details) {
    final draggedKey = details.data;
    if (draggedKey == targetKey) return;
    final layout = _layout;
    if (layout == null) return;
    // details.offset is the drag feedback's top-left corner; the grab
    // offset captured at drag start recovers the pointer position.
    final fx = _fractionOnTile(targetKey, details.offset + _grabOffset);
    final bothApps =
        draggedKey.startsWith('app:') && targetKey.startsWith('app:');
    final center = (fx - 0.5).abs();
    if (LauncherLayoutStore.isFolderKey(targetKey)) {
      // Dropping ON a folder is unambiguous — immediate intent.
      if (_folderHoverKey != targetKey || _previewOrder != null) {
        setState(() {
          _folderHoverKey = targetKey;
          _previewOrder = null;
        });
      }
      return;
    }
    if (bothApps) {
      if (_folderHoverKey == targetKey) {
        // Armed: hold until the pointer leaves the wider band (no flicker
        // at the boundary).
        if (center <= 0.3) return;
        setState(() => _folderHoverKey = null);
      } else if (center <= 0.2) {
        // Center band: arm folder intent only after a dwell — see dartdoc.
        if (_folderDwellKey != targetKey) {
          _cancelFolderDwell();
          _folderDwellKey = targetKey;
          _folderDwell = Timer(const Duration(milliseconds: 450), () {
            if (mounted && _folderDwellKey == targetKey) {
              setState(() {
                _folderHoverKey = targetKey;
                _previewOrder = null;
              });
            }
          });
        }
        return;
      }
    }
    _cancelFolderDwell();
    // Reorder dead zone: once a preview exists, the before/after decision
    // only flips outside fx 0.35..0.65 — dragging a big tile across a slot
    // boundary no longer oscillates the whole grid.
    if (_previewOrder != null && fx > 0.35 && fx < 0.65) {
      if (_folderHoverKey != null) {
        setState(() => _folderHoverKey = null);
      }
      return;
    }
    _previewInsert(draggedKey, targetKey, fx);
  }

  /// Folder-intent dwell timer (see [_onDragHover]).
  Timer? _folderDwell;
  String? _folderDwellKey;

  void _cancelFolderDwell() {
    _folderDwell?.cancel();
    _folderDwell = null;
    _folderDwellKey = null;
  }

  /// Applies one live reorder-preview step: [draggedKey] inserted
  /// before/after [targetKey] at horizontal fraction [fx] (the same math
  /// the drop persists). Shared by the per-tile hover and the grid
  /// background drop surface.
  void _previewInsert(String draggedKey, String targetKey, double fx) {
    final layout = _layout;
    if (layout == null) return;
    final order = _previewOrder ?? layout.topLevelKeys;
    final insertion = launcherInsertionIndex(
      order: order,
      draggedKey: draggedKey,
      targetKey: targetKey,
      fx: fx,
    );
    if (insertion < 0) return;
    final next = moveLauncherKey(order, draggedKey, insertion);
    if (!_sameKeys(next, order)) {
      setState(() {
        _folderHoverKey = null;
        _previewOrder = next;
      });
    } else if (_folderHoverKey != null) {
      setState(() => _folderHoverKey = null);
    }
  }

  /// The grid stack's render box — converts global drag coordinates to
  /// grid-local for the background drop surface.
  RenderBox? _gridBox;

  /// The last resolved background hover target (key, fx) — the background
  /// drop accepts onto it.
  (String, double)? _backgroundTarget;

  /// Continuous hover over the grid BACKGROUND (gaps, row ends, above the
  /// first row): resolves the pointer to the nearest tile + before/after
  /// and drives the same live preview — iOS lets you drop a tile into the
  /// very first slot, and so do we.
  void _onGridBackgroundHover(
    DragTargetDetails<String> details,
    List<String> keys,
    List<TileRect> rects,
  ) {
    final layout = _layout;
    final box = _gridBox;
    if (layout == null || box == null || keys.isEmpty) return;
    final pointer = box.globalToLocal(details.offset + _grabOffset);
    final (targetKey, fx) = _gridHoverTarget(pointer, keys, rects);
    _backgroundTarget = (targetKey, fx);
    _previewInsert(details.data, targetKey, fx);
  }

  /// Maps a grid-local pointer to (targetKey, fx): above the first row →
  /// before the first tile; inside a row → the tile whose center is right
  /// of the pointer (or after the row's last); below → after the last.
  /// Rows are grouped by y because first-fit packing backfills holes (y is
  /// NOT monotonic in index).
  (String, double) _gridHoverTarget(
    Offset pointer,
    List<String> keys,
    List<TileRect> rects,
  ) {
    final rowTops = <double>{for (final r in rects) r.y}.toList()..sort();
    if (pointer.dy < rowTops.first) return (keys.first, 0);
    for (final top in rowTops) {
      final indices = [
        for (var i = 0; i < rects.length; i++)
          if (rects[i].y == top) i,
      ]..sort((a, b) => rects[a].x.compareTo(rects[b].x));
      final rowBottom = indices
          .map((i) => rects[i].y + rects[i].h)
          .reduce((a, b) => a > b ? a : b);
      if (pointer.dy > rowBottom) continue;
      for (final i in indices) {
        if (pointer.dx < rects[i].x + rects[i].w / 2) return (keys[i], 0);
      }
      return (keys[indices.last], 1);
    }
    return (keys.last, 1);
  }

  /// One drop onto the slot of [targetKey]: folder-add on folder tiles,
  /// folder-create when the center-band hover armed folder intent, reorder
  /// elsewhere (left half inserts before, right half after — the same math
  /// the live preview used). [avatarTopLeft] is the drag-feedback's
  /// top-left corner (what `DragTargetDetails.offset` carries); the fixed
  /// drag anchor recovers the pointer position.
  void _onDrop(String draggedKey, String targetKey, Offset avatarTopLeft) {
    final layout = _layout;
    if (layout == null) {
      _clearDragPreview();
      return;
    }
    if (draggedKey != targetKey && LauncherLayoutStore.isFolderKey(targetKey)) {
      layout.addToFolder(LauncherLayoutStore.folderIdOf(targetKey), draggedKey);
      _clearDragPreview();
      return;
    }
    final bothApps =
        draggedKey.startsWith('app:') && targetKey.startsWith('app:');
    if (draggedKey != targetKey && bothApps && _folderHoverKey == targetKey) {
      final apps = _appsById;
      final nameA = apps[draggedKey.substring(4)]?.name;
      final nameB = apps[targetKey.substring(4)]?.name;
      final autoName = nameA != null && nameB != null
          ? '$nameA & $nameB'
          : context.l10n.launcherFolderDefaultName;
      layout.createFolder(draggedKey, targetKey, name: autoName);
      _clearDragPreview();
      return;
    }
    // The live preview IS the arrangement the user saw — apply it as-is,
    // even when the pointer ended over the dragged tile itself (its own
    // slot rejects drops, which is exactly where a big tile's pointer
    // usually is). Only without a preview fall back to the slot math.
    final preview = _previewOrder;
    if (preview != null) {
      _clearDragPreview();
      layout.applyTopLevelOrder(preview);
      return;
    }
    if (draggedKey == targetKey) return;
    final order = layout.topLevelKeys;
    final from = order.indexOf(draggedKey);
    final to = launcherInsertionIndex(
      order: order,
      draggedKey: draggedKey,
      targetKey: targetKey,
      fx: _fractionOnTile(targetKey, avatarTopLeft + _grabOffset),
    );
    if (from < 0 || to < 0) return;
    layout.reorder(from, to);
  }

  /// The drag ended: a real drag applies the LAST previewed arrangement
  /// (iOS semantics — what you saw when you let go is what you get), even
  /// when the pointer was released outside any accepting slot. When the
  /// drag never left its tile and carried ~no velocity, this was a
  /// hold-release WITHOUT movement — the iOS "edit menu" gesture — so
  /// open the tile menu.
  void _onDragCanceled(String key, Velocity velocity, Offset offset) {
    final preview = _previewOrder;
    final hadPreview = preview != null || _folderHoverKey != null;
    _clearDragPreview();
    if (hadPreview) {
      // A real drag cancelled outside any target: keep the arrangement
      // the user last saw instead of snapping back.
      if (preview != null) _layout?.applyTopLevelOrder(preview);
      return;
    }
    if (velocity.pixelsPerSecond.distance > _holdMaxVelocity) return;
    final box = _tileBoxes[key];
    if (box == null || !box.hasSize) return;
    // The offset is the feedback's top-left corner; recover the pointer.
    final pointer = offset + _grabOffset;
    final local = box.globalToLocal(pointer);
    final inside =
        local.dx >= 0 &&
        local.dx <= box.size.width &&
        local.dy >= 0 &&
        local.dy <= box.size.height;
    if (inside) unawaited(_showTileMenu(key, pointer));
  }

  void _clearDragPreview() {
    _cancelFolderDwell();
    if (_previewOrder == null && _folderHoverKey == null) return;
    setState(() {
      _previewOrder = null;
      _folderHoverKey = null;
    });
  }

  /// The horizontal fraction (0..1) of [globalPointer] within [key]'s slot;
  /// 0.5 when the slot's render box is unknown.
  double _fractionOnTile(String key, Offset globalPointer) {
    final box = _tileBoxes[key];
    if (box != null && box.hasSize && box.size.width > 0) {
      final local = box.globalToLocal(globalPointer);
      return (local.dx / box.size.width).clamp(0.0, 1.0);
    }
    return 0.5;
  }

  static bool _sameKeys(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // --- tile menu (hold-release without movement) ---------------------------

  /// The iOS-style tile context menu: live-tile apps get size choices
  /// (Small 2x2 / Medium 4x2 / Large 4x4, persisted as a `tileSizes`
  /// override) plus "Reset to default" while an override exists.
  /// Non-widget apps get no menu (nothing to offer yet).
  Future<void> _showTileMenu(String key, Offset globalPosition) async {
    if (!key.startsWith('app:')) return;
    final app = _appsById[key.substring(4)];
    final tile = app?.tileWidget;
    final layout = _layout;
    if (app == null || tile == null || layout == null) return;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final appId = app.id;
    final override = layout.tileSizeFor(appId);
    final current = override ?? (w: tile.widthCells, h: tile.heightCells);
    final choices = <({String label, TileSize size})>[
      (label: context.l10n.launcherTileSizeSmall, size: (w: 2, h: 2)),
      (label: context.l10n.launcherTileSizeMedium, size: (w: 4, h: 2)),
      (label: context.l10n.launcherTileSizeLarge, size: (w: 4, h: 4)),
    ];
    final selected = await showMenu<Object?>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final choice in choices)
          PopupMenuItem<Object?>(
            value: choice.size,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: choice.size == current
                      ? const Icon(Icons.check, size: 18)
                      : null,
                ),
                Text(choice.label),
              ],
            ),
          ),
        if (override != null)
          PopupMenuItem<Object?>(
            value: 'reset',
            child: Text(context.l10n.launcherTileSizeReset),
          ),
      ],
    );
    if (selected == 'reset') {
      layout.setTileSize(appId, null);
    } else if (selected is TileSize) {
      layout.setTileSize(appId, selected);
    }
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
          // The same store instance the launcher listens to — grid changes
          // apply live.
          layoutStore: _layout,
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

  /// The active-session indicator in the header: which conversation the
  /// agent is in right now (custom or date-derived title); tapping expands
  /// the session sheet. Rebuilds on every manager change (switch/rename).
  Widget _buildSessionChip(FahColors colors) {
    final active = widget.manager.active;
    if (active == null) return const SizedBox.shrink();
    final title =
        widget.sessionNamesStore?.titleFor(active.id) ??
        derivedSessionTitle(
          context,
          id: active.id,
          createdAt: active.createdAt,
        );
    return GestureDetector(
      onTap: () => _sheetKey.currentState?.expand(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: colors.panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(Icons.chat_bubble_outline, size: 13, color: colors.dim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.dim),
              ),
            ),
          ],
        ),
      ),
    );
  }

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
              key: _sheetKey,
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
              // The screen title yields to the session chip on narrow frames:
              // it ellipsizes first, the chip keeps a readable width.
              Flexible(
                child: Text(
                  context.l10n.appsGridTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              _buildSessionChip(colors),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final crossAxisCount = _crossAxisCount(constraints.maxWidth);
              // iOS-like distribution: the 16px side padding stays, the
              // leftover width stretches the gaps (capped) so the grid
              // always fills the screen width instead of huddling in the
              // center with dead margins.
              final spacing = _gridSpacing(
                constraints.maxWidth,
                crossAxisCount,
              );
              final keys = _previewOrder ?? layout.topLevelKeys;
              final rects = layOutTileRects(
                crossAxisCount: crossAxisCount,
                spans: [for (final key in keys) _tileSpan(key, crossAxisCount)],
                spacing: spacing,
                // Only the CROSS-axis gaps stretch with the screen width —
                // the row gap stays the tight spec default.
                mainAxisSpacing: LauncherGridSpec.spacing,
              );
              final gridWidth =
                  crossAxisCount * LauncherGridSpec.cellCrossExtent +
                  (crossAxisCount - 1) * spacing;
              return SingleChildScrollView(
                // Bottom clearance for the floating mini chat bar (bar
                // height + its margin above the home indicator).
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  MediaQuery.viewPaddingOf(context).bottom + 128,
                ),
                child: Center(
                  child: SizedBox(
                    width: gridWidth,
                    height: packedTilesHeight(rects),
                    // No clipping: edge-column labels bleed a few px into
                    // the screen padding (iOS-style) instead of being cut
                    // mid-glyph at the grid's edge.
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Background drop surface BEHIND the tiles: covers
                        // the gaps, row ends, and the space above the first
                        // row, so any landing spot resolves to a live
                        // insertion (the tiles' own targets win on top).
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, _) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                final box = context.findRenderObject();
                                if (box is RenderBox && mounted) {
                                  _gridBox = box;
                                }
                              });
                              return DragTarget<String>(
                                onMove: (details) => _onGridBackgroundHover(
                                  details,
                                  keys,
                                  rects,
                                ),
                                onAcceptWithDetails: (details) {
                                  final target = _backgroundTarget;
                                  if (target != null) {
                                    _onDrop(
                                      details.data,
                                      target.$1,
                                      details.offset,
                                    );
                                  }
                                },
                                builder: (context, _, _) =>
                                    const SizedBox.expand(),
                              );
                            },
                          ),
                        ),
                        for (var i = 0; i < keys.length; i++)
                          AnimatedPositioned(
                            key: ValueKey('tilePos:${keys[i]}'),
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            left: rects[i].x,
                            top: rects[i].y,
                            width: rects[i].w,
                            height: rects[i].h,
                            child: _buildCell(colors, keys[i], spacing),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// The grid column count: the layout's `grid.columns` override when set,
  /// else 4 on narrow screens / 6 on wide ones — clamped to the store's
  /// 3..8 range and to what actually fits the available width.
  int _crossAxisCount(double width) {
    final configured = _layout?.gridColumns ?? (width < 600 ? 4 : 6);
    final fits =
        ((width + LauncherGridSpec.spacing) /
                (LauncherGridSpec.cellCrossExtent + LauncherGridSpec.spacing))
            .floor()
            .clamp(1, LauncherLayoutStore.maxGridColumns);
    return configured
        .clamp(
          LauncherLayoutStore.minGridColumns,
          LauncherLayoutStore.maxGridColumns,
        )
        .clamp(1, fits);
  }

  /// Gap between cells for the current width: the side padding (16+16)
  /// stays fixed, the leftover width distributes into the gaps — iOS-like
  /// full-width grids on any screen. Capped so huge windows keep sane
  /// spacing (the grid then centers, as before).
  static double _gridSpacing(double width, int columns) {
    if (columns <= 1) return LauncherGridSpec.spacing;
    const minSpacing = LauncherGridSpec.spacing;
    const maxSpacing = 44.0;
    final inner = width - 32; // the GridView's horizontal padding
    final raw = (inner - columns * LauncherGridSpec.iconSize) / (columns - 1);
    return raw.clamp(minSpacing, maxSpacing);
  }

  /// The grid span of one tile: apps with a live tile get their WxH —
  /// the `tileSizes` override when set, else the manifest's declared size
  /// (width clamped to the column count); everything else is one icon slot.
  TileSpan _tileSpan(String key, int crossAxisCount) {
    if (key.startsWith('app:')) {
      final appId = key.substring(4);
      final tile = _appsById[appId]?.tileWidget;
      if (tile != null) {
        final override = _layout?.tileSizeFor(appId);
        final w = override?.w ?? tile.widthCells;
        final h = override?.h ?? tile.heightCells;
        return (w: w.clamp(1, crossAxisCount), h: h);
      }
    }
    return (w: 1, h: 1);
  }

  /// The drag feedback: classic tiles drag their 64px icon; apps with a
  /// live tile drag a FULL-SIZE static replica of the card (rounded panel
  /// with the app icon and name) so it is obvious WHAT is being dragged —
  /// spinning up a second live engine just for the avatar would be
  /// pointless weight.
  Widget _tileFeedback(
    FahColors colors,
    String key,
    BoxConstraints constraints,
  ) {
    final app = key.startsWith('app:') ? _appsById[key.substring(4)] : null;
    if (app != null && app.tileWidget != null) {
      return Container(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        decoration: BoxDecoration(
          color: colors.panelAlt,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(app: app, env: widget.manager.env, size: 32),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.text),
              ),
            ),
          ],
        ),
      );
    }
    return _maybeSeedErrorBadge(
      colors,
      key,
      _tileIcon(colors, key, size: _feedbackSize),
    );
  }

  Widget _buildCell(FahColors colors, String key, double spacing) {
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final box = context.findRenderObject();
          if (box is RenderBox && mounted) _tileBoxes[key] = box;
        });
        return DragTarget<String>(
          key: ValueKey('launcherCell:$key'),
          onWillAcceptWithDetails: (details) => details.data != key,
          onMove: (details) => _onDragHover(key, details),
          onAcceptWithDetails: (details) =>
              _onDrop(details.data, key, details.offset),
          builder: (context, candidateData, rejectedData) {
            final folderHover = _folderHoverKey == key;
            return LongPressDraggable<String>(
              data: key,
              // Anchor the feedback at the GRAB POINT inside the tile (and
              // remember it for the hover/drop pointer math above): a
              // widget card is dragged by exactly the spot the user holds.
              dragAnchorStrategy: (draggable, context, position) {
                final box = context.findRenderObject();
                if (box is RenderBox && box.hasSize) {
                  _grabOffset = box.globalToLocal(position);
                }
                return _grabOffset;
              },
              onDraggableCanceled: (velocity, offset) =>
                  _onDragCanceled(key, velocity, offset),
              // NOTE the framework's callback order: onDragEnd fires
              // BEFORE onDraggableCanceled. Never clear the preview here
              // on rejection — _onDragCanceled needs it to apply the last
              // previewed arrangement.
              onDragEnd: (details) {
                if (details.wasAccepted) _clearDragPreview();
              },
              feedback: Material(
                color: Colors.transparent,
                child: Opacity(
                  opacity: 0.9,
                  child: _tileFeedback(colors, key, constraints),
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: _tileContent(colors, key, spacing),
              ),
              child: AnimatedScale(
                scale: folderHover
                    ? 1.12
                    : (candidateData.isNotEmpty ? 1.08 : 1),
                duration: const Duration(milliseconds: 120),
                child: _tileContent(colors, key, spacing),
              ),
            );
          },
        );
      },
    );
  }

  /// The tile body: the icon slot (icon square + label strip, exactly one
  /// [LauncherGridSpec] cell) — or, for apps declaring a `"widget"`
  /// manifest section, the live tile ([AppTileHost]) filling its WxH span
  /// edge-to-edge with the icon block it replaces. Taps launch/navigate;
  /// folder taps open the folder panel.
  Widget _tileContent(FahColors colors, String key, double spacing) {
    final theme = Theme.of(context);
    if (key.startsWith('app:')) {
      final app = _appsById[key.substring(4)];
      final tile = app?.tileWidget;
      if (app != null && tile != null) {
        // Live tile: the app draws its own mini UI (icon+label replaced);
        // any tap opens the full app.
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _onTileTap(key),
          child: AppTileHost(
            app: app,
            env: widget.manager.env,
            fsRevision: widget.manager.active?.service.fsRevision,
            engineFactory: widget.tileEngineFactory,
            onOpen: () => _onTileTap(key),
          ),
        );
      }
    }
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _onTileTap(key),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          _maybeSeedErrorBadge(colors, key, _tileIcon(colors, key)),
          SizedBox(
            height: LauncherGridSpec.labelHeight,
            // iOS-style: the label may bleed into the (empty) inter-icon
            // gap, so it measures up to one cell PITCH wide, not just the
            // icon square — keeps names like "Habit Tracker" readable.
            child: OverflowBox(
              alignment: Alignment.topCenter,
              maxWidth: LauncherGridSpec.cellCrossExtent + spacing,
              child: Text(
                _tileLabel(key),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
              ),
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

  /// The corner badge on a tile whose demo seed failed (missing/corrupt
  /// asset): the app stays on the grid — flagged, never fatal.
  Widget _maybeSeedErrorBadge(FahColors colors, String key, Widget tile) {
    if (!key.startsWith('app:')) return tile;
    final failed = _appsStore.failedSeeds.value;
    if (!failed.contains(key.substring(4))) return tile;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        tile,
        Positioned(
          top: -3,
          right: -3,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: colors.error,
              shape: BoxShape.circle,
              border: Border.all(color: colors.bg, width: 2),
            ),
            child: const Center(
              child: Text(
                '!',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ],
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
                              // 64px icon feedback centered on the
                              // pointer (folder-panel drags need no
                              // grab-point math).
                              const Offset(32, 32),
                          feedback: Material(
                            color: Colors.transparent,
                            child: Opacity(
                              opacity: 0.9,
                              child: _maybeSeedErrorBadge(
                                colors,
                                tile,
                                _tileIcon(colors, tile, size: _feedbackSize),
                              ),
                            ),
                          ),
                          childWhenDragging: Opacity(
                            opacity: 0.35,
                            child: _tileContent(
                              colors,
                              tile,
                              LauncherGridSpec.spacing,
                            ),
                          ),
                          child: _tileContent(
                            colors,
                            tile,
                            LauncherGridSpec.spacing,
                          ),
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
