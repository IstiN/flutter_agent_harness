import 'dart:math' as math;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/ui/widgets/file_preview.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart'
    show MessengerGlassUnderlay;
import 'package:fa/ui/widgets/session_search_field.dart'
    show SessionSearchField;
import 'package:fa/services/icloud_sync_service.dart';
import 'package:fa/services/project_folder_channel.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/project_mount_flow.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/services/upload_picker_stub.dart'
    if (dart.library.io) 'package:fa/services/upload_picker_io.dart'
    if (dart.library.html) 'package:fa/services/upload_picker_web.dart';
import 'package:fa_ui/fa_ui.dart' hide formatFileSize;

/// The default [ProjectFolderOps] on supported platforms (macOS), else null.
ProjectFolderOps? _defaultProjectFolderOps() =>
    ProjectFolderChannelOps.isSupported
    ? const ProjectFolderChannelOps()
    : null;

/// Width of the file browser panel (right side panel on wide layouts, end
/// drawer on narrow ones).
const double kFileBrowserPanelWidth = 300;

/// File browser over the agent's [ExecutionEnv].
///
/// Folders navigate (breadcrumb + up), files open a preview — inline in the
/// panel when [inlinePreview] is true (wide layouts), or as a pushed
/// [FilePreviewScreen] route otherwise (narrow layouts).
///
/// The header offers an upload button (when an [UploadPicker] is available,
/// i.e. on web or when one is injected) that writes picked files into the
/// currently viewed folder, so they land in the same sandbox filesystem the
/// agent's tools see.
///
/// When [fsRevision] is provided (see `AgentService.fsRevision`), every
/// bump refreshes the current directory listing and reloads the open
/// preview — that is how the browser learns the agent changed files,
/// without polling.
///
/// Typed against the [ExecutionEnv] abstraction only, so a cloud-backed env
/// can drop in later without UI changes. Navigation uses paths relative to
/// the env's working directory (never [FileInfo.path]): relative paths
/// resolve against the sandbox root on every backend, whereas returned
/// absolute paths are not portable across envs (e.g. the mobile sandbox maps
/// `/`-rooted paths onto a host directory).
class FileBrowser extends StatefulWidget {
  const FileBrowser({
    super.key,
    required this.env,
    this.initialPath,
    this.sessionFolder,
    this.inlinePreview = true,
    this.uploadPicker,
    this.iCloudSyncService,
    this.maxUploadBatchBytes = kMaxUploadBatchBytes,
    this.fsRevision,
    this.htmlPreviewBuilder,
    this.projectFolderOps,
    this.onProjectMountChanged,
    this.showHeader = true,
    this.topCenterline = false,
    this.filterController,
    this.onClose,
    this.surfaceBorder,
    this.headerKey,
    this.searchKey,
    this.closeKey,
  });

  /// The environment whose filesystem is browsed — the same instance the
  /// agent's tools use (see `AgentService.env`).
  final ExecutionEnv env;

  /// Folder the listing opens in — the session's working directory (the
  /// host passes `service.currentSessionCwd`). Absolute paths are used
  /// as-is and rebased onto the env cwd when they live under it; relative
  /// paths resolve against the env cwd (`FileSystem.cwd`). Null (or
  /// empty) keeps today's behavior — the listing starts at the env cwd.
  final String? initialPath;

  /// The active session's own folder (`service.currentSessionCwd`),
  /// kept separately from [initialPath]: when this folder is NOT one of
  /// the env's visible roots ([visibleFolderRoot] null — a host path the
  /// sandbox/mount cannot open), the browser shows the session-folder
  /// access gate instead of silently listing the mount root. Null (a
  /// personal session) never gates.
  final String? sessionFolder;

  /// Whether file previews render inside the panel (true) or push a
  /// full-screen route (false).
  final bool inlinePreview;

  /// File chooser behind the upload button. Defaults to the platform picker
  /// (`null` off the web → the button is hidden); tests inject a fake.
  final UploadPicker? uploadPicker;

  /// iCloud sync backend behind the header's sync button. Defaults to the
  /// platform service (`null` off macOS/iOS → the button is hidden); tests
  /// inject a fake (same pattern as [uploadPicker]).
  final ICloudSyncService? iCloudSyncService;

  /// Total-byte cap for one upload batch; oversized batches are refused
  /// with a message before anything is written.
  final int maxUploadBatchBytes;

  /// Agent filesystem revision: every bump reloads the listing and the open
  /// preview. `null` disables auto-refresh (manual refresh still works).
  final ValueListenable<int>? fsRevision;

  /// Override for the HTML rendering surface; tests inject a fake because
  /// the webview plugin has no platform implementation on the host.
  final HtmlPreviewBuilder? htmlPreviewBuilder;

  /// Native project-folder operations behind the open-folder control
  /// (macOS sandbox flow); defaults to the channel ops when supported.
  /// Tests inject a fake.
  final ProjectFolderOps? projectFolderOps;

  /// Fired after the project-folder mount changes (mount/unmount), so the
  /// host can recompose the agent's system prompt.
  final void Function()? onProjectMountChanged;

  /// Biases the band's circles onto the host header's shared action
  /// centerline (the docked Files surface sits beside the chat header's
  /// collapse toggle). Standalone hosts keep the symmetric centering.
  final bool topCenterline;

  /// Whether the browser paints its own header row. Host surfaces that
  /// already provide the chrome band (the presented Files card) turn it
  /// off — the path bar, hairline and listing stay. Default keeps the
  /// full self-contained chrome.
  final bool showHeader;

  /// Live name filter driven by a host-owned search field (the presented
  /// Files card's capsule). Null keeps the listing unfiltered.
  final TextEditingController? filterController;

  /// Closes the Files surface: rendered as the band's trailing circle
  /// (the presented pane and pushed routes pop through it). Null hides
  /// the circle — hosts that toggle the surface themselves (the chat
  /// header's Files button) pass nothing.
  final VoidCallback? onClose;

  /// Whether the browser paints the legacy left hairline on its Material.
  /// Standalone surfaces keep it; hosts that embed the browser inside a
  /// card (the shared Files pane) turn it off — the card already draws
  /// its own edge.
  final bool? surfaceBorder;

  /// Key overrides for the shared band's slots. Defaults keep the
  /// browser's own lookup keys ([showHeader] standalone); the shared pane
  /// passes its golden-stable keys through.
  final Key? headerKey;
  final Key? searchKey;
  final Key? closeKey;

  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  /// Current directory as segments relative to the env root (`[]` = root).
  final List<String> _segments = [];

  /// The band's search capsule: the host-owned filter when provided, else
  /// an owned controller (disposed with the browser).
  final TextEditingController _ownedSearch = TextEditingController();
  late final TextEditingController _search =
      widget.filterController ?? _ownedSearch;
  final _searchFocus = FocusNode(debugLabel: 'file-browser-search');
  var _searchVisible = false;

  List<FileInfo>? _entries;
  String? _error;

  /// The mount env when the agent's env is one (desktop/macOS); null
  /// elsewhere (the open-folder control hides then). Looks through the
  /// [SecretsExecutionEnv] wrapper the agent service always puts around
  /// the shared env.
  ProjectMountEnv? get _mountEnv => resolveProjectMountEnv(widget.env);

  /// The active session's folder when Files CANNOT list it through the
  /// env's visible roots ([visibleFolderRoot] null): a host path outside
  /// the sandbox/mount roots. Files must not silently list a different
  /// folder (the active mount) in its place — it shows the access
  /// affordance instead ([_buildSessionFolderGate]). Null (no session
  /// folder, or one the env can already open) keeps today's listing.
  String? get _gatedSessionFolder {
    final folder = widget.sessionFolder?.trim();
    if (folder == null || folder.isEmpty) return null;
    final name = folder.split('/').where((s) => s.isNotEmpty).lastOrNull;
    if (name == null || name == '.' || name == '..') return null;
    return visibleFolderRoot(widget.env, folder) == null ? folder : null;
  }

  /// The gate's affordance action: the EXISTING security-scoped flow
  /// ([pickAndApplyProjectMount] — native picker → bookmark resolve →
  /// [ProjectMountStore] persist → mount switch → host notify). A grant
  /// of the session's folder switches the listing to it; a decline or
  /// failure keeps the affordance (no silent wrong listing).
  Future<void> _grantSessionFolder() async {
    final folder = widget.sessionFolder?.trim();
    await _pickProjectFolder();
    if (!mounted) return;
    if (_gatedSessionFolder != null) return; // decline / other folder picked
    // Granted: the mount IS the session's folder now — jump the listing
    // to the visible root the env can actually open (the resolved mount
    // path; a session folder must never fall back to the old segments).
    final visible = visibleFolderRoot(widget.env, folder);
    if (visible == null) return;
    setState(() {
      _segments
        ..clear()
        ..addAll(_initialSegments(visible));
      _preview = null;
    });
    await _load();
  }

  Future<void> _pickProjectFolder() async {
    final ops = widget.projectFolderOps ?? _defaultProjectFolderOps();
    final String? picked;
    try {
      picked = await pickAndApplyProjectMount(
        env: widget.env,
        ops: ops,
        onApplied: () => widget.onProjectMountChanged?.call(),
        onAccessDenied: () {
          if (mounted) {
            showFahErrorSnack(context, context.l10n.filesFolderAccessDenied);
          }
        },
      );
    } on Object catch (e) {
      if (mounted) {
        showFahErrorSnack(
          context,
          context.l10n.filesFolderPickerError(e.toString()),
        );
      }
      return;
    }
    if (picked == null) return;
    setState(() {});
    await _load();
  }

  Future<void> _unmountProjectFolder() async {
    final cleared = await unapplyProjectMount(
      env: widget.env,
      ops: widget.projectFolderOps ?? _defaultProjectFolderOps(),
      onApplied: () => widget.onProjectMountChanged?.call(),
    );
    if (!cleared) return;
    setState(() {});
    await _load();
  }

  bool _loading = true;

  /// Inline preview target, when [FileBrowser.inlinePreview] is on.
  ({String path, String name})? _preview;

  /// Counter folded into the inline preview's key: bumping it forces the
  /// preview to re-read its file (agent-side mutation hook).
  int _previewRevision = 0;

  /// Resolved picker: the injected one, else the platform default (`null`
  /// off the web, which hides the upload button).
  late final UploadPicker? _picker =
      widget.uploadPicker ?? createUploadPicker();

  /// iCloud sync backend behind the header's sync button; `null` off
  /// macOS/iOS (web/Android), which hides the button. Manual trigger only.
  late final ICloudSyncService? _iCloudSync =
      widget.iCloudSyncService ??
      (icloudSyncSupported ? createICloudSyncService(widget.env) : null);

  @override
  void initState() {
    super.initState();
    widget.fsRevision?.addListener(_onFsRevision);
    _search.addListener(_onFilterChanged);
    _searchFocus.addListener(_onSearchFocusChanged);
    _segments.addAll(_initialSegments(widget.initialPath));
    _load();
  }

  @override
  void didUpdateWidget(FileBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fsRevision != widget.fsRevision) {
      oldWidget.fsRevision?.removeListener(_onFsRevision);
      widget.fsRevision?.addListener(_onFsRevision);
    }
    if (oldWidget.filterController != widget.filterController) {
      oldWidget.filterController?.removeListener(_onFilterChanged);
      _search.addListener(_onFilterChanged);
    }
    // The host swapped the session under an open panel: jump to the new
    // session's folder (the same resolution [initialPath] documents).
    if (oldWidget.initialPath != widget.initialPath) {
      _segments
        ..clear()
        ..addAll(_initialSegments(widget.initialPath));
      _preview = null;
      _load();
    }
  }

  @override
  void dispose() {
    widget.fsRevision?.removeListener(_onFsRevision);
    _search.removeListener(_onFilterChanged);
    _searchFocus.removeListener(_onSearchFocusChanged);
    if (widget.filterController == null) _ownedSearch.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Host-side search capsule typed into — re-run the (cheap) name filter.
  void _onFilterChanged() {
    if (mounted) setState(() {});
  }

  void _onSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onSearchReveal() {
    setState(() => _searchVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _onSearchClose() {
    _search.clear();
    _searchFocus.unfocus();
    setState(() => _searchVisible = false);
  }

  /// Agent-side filesystem change ("hook"): reload the listing and force
  /// the open preview to re-read its file. Conservative — a bump does not
  /// say which file changed (`bash` can touch anything), and one extra
  /// listDir/read is cheap.
  void _onFsRevision() {
    if (_preview != null) _previewRevision++;
    _load();
  }

  /// Path of the current directory in the env namespace. Relative to the
  /// env's working directory EXCEPT at a LIVE mounted root: there the
  /// browser's root IS the mount segment ([projectMountSegment]) — a bare
  /// '.' would resolve against the delegate's own cwd (the app container),
  /// listing the container instead of the mounted project folder ('Could
  /// not list folder' on the sandboxed desktop when the container has no
  /// such path). Mount machinery without a live mount keeps the env cwd:
  /// an unmounted host has no '/project' to open, and asking for the
  /// segment anyway reported 'Could not open folder' in place of the
  /// personal (container/sandbox) root listing.
  String get _envPath => _segments.isEmpty
      ? (_mountEnv?.mountedRoot != null ? projectMountSegment : '.')
      : _segments.join('/');

  String _childPath(String name) =>
      _segments.isEmpty ? name : '${_segments.join('/')}/$name';

  List<String> _segmentsOf(String path) => [
    for (final segment in path.split('/'))
      if (segment.isNotEmpty && segment != '.') segment,
  ];

  List<String> _resolveSegments(String target) {
    final resolved = <String>[];
    for (final segment in _segmentsOf(target)) {
      if (segment == '..') {
        if (resolved.isNotEmpty) resolved.removeLast();
        continue;
      }
      resolved.add(segment);
    }
    return resolved;
  }

  /// Segments (cwd-relative) that open the browser in [path]:
  /// [FileBrowser.initialPath] resolution. Relative paths resolve against
  /// the env cwd; absolute ones are used as-is, rebased onto the cwd when
  /// they live under it (the local desktop env's cwd IS the session
  /// folder, so the session folder opens as the root listing). Null or
  /// empty yields no segments — the env cwd itself.
  List<String> _initialSegments(String? path) {
    var target = path?.trim() ?? '';
    if (target.isEmpty || target == '.') return const [];
    final cwd = widget.env.cwd;
    if (!target.startsWith('/')) {
      target = cwd.endsWith('/') ? '$cwd$target' : '$cwd/$target';
    }
    // Resolve `..` on the absolute target (the cwd keeps `..` inside it —
    // the browser never escapes its root namespace).
    final resolved = _resolveSegments(target);
    final cwdSegments = _segmentsOf(cwd);
    final underCwd =
        resolved.length >= cwdSegments.length &&
        _segmentsStartWith(resolved, cwdSegments);
    if (underCwd) return resolved.sublist(cwdSegments.length);
    // The mount namespace: a host absolute path under the mounted root
    // lives INSIDE the mount at [projectMountSegment] — rebase onto the
    // mount root so the listing goes through the env's host mapping.
    // Without this, a mounted session's host path (the
    // [visibleFolderRoot] initialPath, or the grant flow's jump) leaks
    // raw host segments into listDir and the panel reports 'Could not
    // list folder' on the sandboxed desktop (delegate cwd is the app
    // container, so 'Users/…' resolves nowhere).
    final mountRoot = _mountEnv?.mountedRoot;
    if (mountRoot != null) {
      final mountSegments = _segmentsOf(mountRoot);
      if (resolved.length >= mountSegments.length &&
          _segmentsStartWith(resolved, mountSegments)) {
        return resolved.sublist(mountSegments.length);
      }
    }
    return resolved;
  }

  /// Whether [path] starts with exactly the [prefix] segments.
  bool _segmentsStartWith(List<String> path, List<String> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (path[i] != prefix[i]) return false;
    }
    return true;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.env.listDir(_envPath);
      if (!mounted) return;
      final entries = result.valueOrNull;
      if (entries == null) {
        setState(() {
          _entries = null;
          _loading = false;
          _error =
              result.errorOrNull?.message ?? context.l10n.filesListFolderError;
        });
        return;
      }
      int byName(FileInfo a, FileInfo b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase());
      final dirs = entries.where((e) => e.kind == FileKind.directory).toList()
        ..sort(byName);
      final files = entries.where((e) => e.kind != FileKind.directory).toList()
        ..sort(byName);
      setState(() {
        _entries = [...dirs, ...files];
        _loading = false;
      });
    } on Object catch (e) {
      // Defensive: FileSystem operations are contract-bound to return Err
      // instead of throwing; keep the UI alive if a backend misbehaves.
      if (!mounted) return;
      setState(() {
        _entries = null;
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _enterDir(FileInfo info) {
    setState(() {
      _segments.add(info.name);
      _preview = null;
    });
    _load();
  }

  void _goUp() {
    if (_segments.isEmpty) return;
    setState(() {
      _segments.removeLast();
      _preview = null;
    });
    _load();
  }

  /// Jumps to the breadcrumb at [index] (-1 = root).
  void _jumpTo(int index) {
    setState(() {
      _segments.removeRange(index + 1, _segments.length);
      _preview = null;
    });
    _load();
  }

  void _openFile(FileInfo info) {
    final path = _childPath(info.name);
    if (widget.inlinePreview) {
      setState(() => _preview = (path: path, name: info.name));
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FilePreviewScreen(
            env: widget.env,
            path: path,
            name: info.name,
            htmlPreviewBuilder: widget.htmlPreviewBuilder,
            fsRevision: widget.fsRevision,
          ),
        ),
      );
    }
  }

  void _showSnack(String message, {bool error = false}) {
    error
        ? showFahErrorSnack(
            context,
            message,
            duration: const Duration(seconds: 3),
            hideCurrent: true,
          )
        : showFahSnack(context, message, duration: const Duration(seconds: 3));
  }

  /// Runs one iCloud merge of the sandbox sessions/apps trees and reports
  /// the outcome as a snackbar (synced counts, or the unavailable guidance
  /// when the ubiquity container is missing).
  Future<void> _syncICloud() async {
    final service = _iCloudSync;
    if (service == null) return;
    await _runSync(service);
  }

  /// Guarded sync body: availability check, one merge, then the outcome
  /// snackbar + reload (extracted so [_syncICloud] stays a thin guard).
  Future<void> _runSync(ICloudSyncService service) async {
    if (!await service.isAvailable()) {
      if (mounted) _showSyncUnavailable();
      return;
    }
    try {
      final report = await service.syncNow();
      if (!mounted) return;
      _showSyncDone(report);
      await _load();
    } on Object catch (e) {
      if (mounted) _showSyncFailed(e);
    }
  }

  void _showSyncUnavailable() =>
      _showSnack(context.l10n.filesICloudSyncUnavailable, error: true);

  void _showSyncDone(ICloudSyncReport report) => _showSnack(
    context.l10n.filesICloudSyncDone(
      report.filesCopied,
      formatFileSize(report.bytesCopied),
      formatICloudSyncTimestamp(report.syncedAt),
    ),
  );

  void _showSyncFailed(Object e) =>
      _showSnack(context.l10n.filesICloudSyncFailed(e.toString()), error: true);

  /// Picks files and writes them into the currently viewed folder of the
  /// sandbox filesystem, so the agent can work with them right away.
  Future<void> _upload() async {
    final picker = _picker;
    if (picker == null) return;
    final picked = await _pickUploadFiles(picker);
    if (picked == null || picked.isEmpty || !mounted) return;
    final sizeError = uploadBatchSizeError(
      picked,
      maxBytes: widget.maxUploadBatchBytes,
      message: (total, max) => context.l10n.uploadTooLarge(max, total),
    );
    if (sizeError != null) {
      _showSnack(sizeError, error: true);
      return;
    }
    await _writeUploadedFiles(picked);
  }

  /// The picked files; null when the picker failed (error snack shown).
  Future<List<UploadFile>?> _pickUploadFiles(UploadPicker picker) async {
    final List<UploadFile> picked;
    try {
      picked = await picker.pick();
    } on Object catch (e) {
      if (mounted) {
        _showSnack(context.l10n.filesUploadFailed(e.toString()), error: true);
      }
      return null;
    }
    return picked;
  }

  Future<void> _writeUploadedFiles(List<UploadFile> picked) async {
    final (written, failed) = await _writeUploadBatch(picked);
    if (!mounted) return;
    if (written > 0) await _load();
    if (!mounted) return;
    _showUploadSummary(written, failed);
  }

  Future<(int, List<String>)> _writeUploadBatch(List<UploadFile> picked) async {
    var written = 0;
    final failed = <String>[];
    final emptyName = context.l10n.filesEmptyFileName;
    for (final file in picked) {
      final name = sanitizeUploadName(file.name);
      if (name.isEmpty) {
        failed.add(file.name.isEmpty ? emptyName : file.name);
        continue;
      }
      final result = await widget.env.writeBinaryFile(
        _childPath(name),
        file.bytes,
      );
      if (result.isOk) {
        written++;
      } else {
        failed.add(name);
      }
    }
    return (written, failed);
  }

  /// Failures stay visible: which files, not just how many.
  void _showUploadSummary(int written, List<String> failed) {
    final failures = failed.isNotEmpty
        ? context.l10n.filesUploadFailures(
            failed.length.toString(),
            failed.join(', '),
          )
        : '';
    _showSnack(context.l10n.filesUploadSummary(failures, written));
  }

  IconData _iconFor(FileInfo info) {
    if (info.kind == FileKind.directory) return Icons.folder_outlined;
    return switch (fileExtension(info.name)) {
      '.png' || '.jpg' || '.jpeg' || '.gif' || '.webp' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    // Chrome stack heights are fixed (header 52, identity chip 32, path or
    // preview bar 44, hairline 1) so the body can pad its top and scroll
    // beneath the chrome band, like the chat list.
    final hasIdentity = _mountEnv?.mountedRoot != null;
    final chromeHeight =
        (widget.showHeader ? 52.0 : 0.0) +
        (hasIdentity ? 32.0 : 0.0) +
        44.0 +
        1.0;
    return Material(
      key: const ValueKey('fileBrowserPanel'),
      // The docked glass card owns the backdrop. An opaque Material here
      // hid it everywhere except the circular buttons themselves.
      color:
          tokens.direction == FaVisualDirection.glass &&
              widget.surfaceBorder == false
          ? Colors.transparent
          : colors.panel,
      shape: (widget.surfaceBorder ?? widget.showHeader)
          ? Border(left: BorderSide(color: colors.border, width: .5))
          : null,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(child: _buildBody(context, chromeHeight)),
          if (tokens.direction == FaVisualDirection.glass)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: chromeHeight + 6,
              child: const MessengerGlassUnderlay(
                underlayKey: ValueKey('fileBrowserChromeUnderlay'),
              ),
            ),
          Positioned(top: 0, left: 0, right: 0, child: _buildChrome(context)),
        ],
      ),
    );
  }

  /// The chrome band: header, mounted identity, path bar (or the inline
  /// preview's back bar) and the closing hairline. In the glass direction
  /// the band's background IS glass — a graduated `ProgressiveBlur` under
  /// the controls, so rows scrolling up dissolve behind the chrome itself
  /// (same pattern as the chat list). Opaque directions keep the flat
  /// panel color.
  Widget _buildChrome(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final chrome = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?_headerRow(context),
        ?_buildMountIdentity(context),
        _preview != null ? _buildPreviewBar(context) : _buildPathBar(context),
        Divider(height: 1, color: colors.border.withValues(alpha: .55)),
      ],
    );
    if (tokens.direction != FaVisualDirection.glass) {
      return ColoredBox(color: colors.panel, child: chrome);
    }
    return chrome;
  }

  /// One circular icon action in the panel chrome (path bar up button,
  /// preview back button): the same [FilesCircleAction] chrome the band
  /// actions use, so every icon button in the Files panel reads as one
  /// family instead of a mix of ad-hoc circles.
  Widget _chromeIconButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) => FilesCircleAction(icon: icon, tooltip: tooltip, onPressed: onPressed);

  /// The panel's own header row — [FileBrowser.showHeader] off hides it
  /// entirely (the host band replaces it). On it renders the ONE shared
  /// [FilesChrome] band, so every Files surface reads alike.
  Widget? _headerRow(BuildContext context) =>
      widget.showHeader ? _buildHeader(context) : null;

  Widget _buildHeader(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final compact =
        faWindowClassForWidth(MediaQuery.sizeOf(context).width) ==
        FaWindowClass.small;
    final searchShown =
        !compact ||
        _searchVisible ||
        _search.text.trim().isNotEmpty ||
        _searchFocus.hasFocus;
    final actions = <FaHeaderAction>[
      FaHeaderAction(
        key: const ValueKey('fileBrowserRefresh'),
        icon: Icons.refresh,
        label: context.l10n.filesRefreshTooltip,
        onPressed: _load,
      ),
      if (_picker != null)
        FaHeaderAction(
          key: const ValueKey('fileBrowserUpload'),
          icon: Icons.upload_file_outlined,
          label: context.l10n.filesUploadTooltip,
          onPressed: _upload,
        ),
      if (_iCloudSync != null)
        FaHeaderAction(
          key: const ValueKey('fileBrowserICloudSync'),
          icon: Icons.cloud_sync_outlined,
          label: context.l10n.filesICloudSyncTooltip,
          onPressed: _syncICloud,
        ),
      ?_buildMountControl(context),
    ];
    return FilesChrome(
      key: widget.headerKey ?? const ValueKey('fileBrowserHeader'),
      searchController: _search,
      searchFocusNode: _searchFocus,
      searchCollapsed: !searchShown,
      onSearchReveal: compact && !searchShown ? _onSearchReveal : null,
      onSearchClose: compact && searchShown ? _onSearchClose : null,
      actions: actions,
      menuColor: tokens.surface2,
      onClose: widget.onClose,
      closeKey: widget.closeKey,
      searchKey: widget.searchKey,
      topCenterline: widget.topCenterline,
    );
  }

  /// The project-folder action uses the same adaptive overflow as every
  /// other panel action. Mounted identity lives in a secondary chip so a
  /// long folder name can never squeeze the Files title or action row.
  FaHeaderAction? _buildMountControl(BuildContext context) {
    final mountEnv = _mountEnv;
    if (mountEnv == null) return null;
    final unavailable = mountEnv.mountUnavailable;
    if (unavailable != null) {
      return FaHeaderAction(
        key: const ValueKey('fileBrowserMount'),
        icon: Icons.warning_amber_outlined,
        label: context.l10n.filesMountUnavailableTooltip(unavailable),
        onPressed: _pickProjectFolder,
      );
    }
    final mountedPath = mountEnv.mountedRoot;
    if (mountedPath != null) {
      return FaHeaderAction(
        key: const ValueKey('fileBrowserMount'),
        icon: Icons.eject_outlined,
        label: context.l10n.filesUnmountTooltip(mountedPath),
        onPressed: _unmountProjectFolder,
      );
    }
    final canPick =
        widget.projectFolderOps != null || ProjectFolderChannelOps.isSupported;
    if (!canPick) return null;
    return FaHeaderAction(
      key: const ValueKey('fileBrowserMount'),
      icon: Icons.create_new_folder_outlined,
      label: context.l10n.filesOpenProjectFolderTooltip,
      onPressed: _pickProjectFolder,
    );
  }

  Widget? _buildMountIdentity(BuildContext context) {
    final mountedPath = _mountEnv?.mountedRoot;
    if (mountedPath == null) return null;
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final name = mountedPath.split('/').where((part) => part.isNotEmpty).last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Tooltip(
          message: mountedPath,
          child: FaSurface(
            glass: true,
            color: tokens.surface1,
            tintAmount: .22,
            tintOpacity: .55,
            borderRadius: BorderRadius.circular(10),
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: SizedBox(
              key: const ValueKey('fileBrowserMountIdentity'),
              height: 28,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_outlined, size: 14, color: colors.dim),
                  const SizedBox(width: 7),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.dim,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
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

  Widget _buildPathBar(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      key: const ValueKey('fileBrowserPathBar'),
      height: 44,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 12, 2),
        child: Row(
          children: [
            _chromeIconButton(
              icon: Icons.arrow_upward,
              tooltip: context.l10n.filesUpTooltip,
              onPressed: _segments.isEmpty ? null : _goUp,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FaSurface(
                glass: true,
                color: tokens.surface1,
                tintAmount: .22,
                tintOpacity: .55,
                borderRadius: BorderRadius.circular(14),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: SizedBox(
                  key: const ValueKey('fileBrowserBreadcrumbChip'),
                  height: 28,
                  child: SingleChildScrollView(
                    key: const ValueKey('fileBrowserBreadcrumbs'),
                    scrollDirection: Axis.horizontal,
                    // The scroll view forces the cross axis tight to the
                    // 28px chip; center keeps the crumbs on its optical
                    // middle line.
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: _breadcrumbs(context),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _breadcrumbs(BuildContext context) {
    final colors = FahColors.of(context);
    final style = TextStyle(color: colors.dim, fontSize: 12, height: 1.2);
    // One line, never wrapped, ellipsized if a single crumb is ever
    // constrained — and no vertical padding: the cross-axis-tight scroll
    // view centers the row in the 28px chip, so padded crumbs (14.4px of
    // text + 16px of padding) overflowed the chip and clipped top/bottom.
    Widget crumb(String label, int index, bool isCurrent) {
      final child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: isCurrent
              ? style.copyWith(color: colors.text, fontWeight: FontWeight.w600)
              : style,
        ),
      );
      if (isCurrent) return child;
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => _jumpTo(index),
        child: child,
      );
    }

    final crumbs = <Widget>[crumb('/', -1, _segments.isEmpty)];
    for (var i = 0; i < _segments.length; i++) {
      crumbs.add(Icon(Icons.chevron_right, size: 14, color: colors.dim));
      crumbs.add(crumb(_segments[i], i, i == _segments.length - 1));
    }
    return crumbs;
  }

  /// The panel body, laid out under the chrome band ([topInset] px down):
  /// the listing scrolls beneath the chrome, so in the glass direction
  /// rows dissolve behind the band exactly like the chat list.
  Widget _buildBody(BuildContext context, double topInset) {
    final colors = FahColors.of(context);
    // A session folder the env cannot open (not the mount, not the
    // container root): the gate REPLACES the listing — never a silent
    // wrong folder under the Files title.
    final gated = _gatedSessionFolder;
    if (gated != null) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: _buildSessionFolderGate(context, gated),
      );
    }
    final preview = _preview;
    if (preview != null) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: FilePreviewView(
          key: ValueKey('${preview.path}#$_previewRevision'),
          env: widget.env,
          path: preview.path,
          name: preview.name,
          htmlPreviewBuilder: widget.htmlPreviewBuilder,
        ),
      );
    }

    if (_loading) {
      return _centered(
        topInset,
        child: CircularProgressIndicator(color: colors.indigo),
      );
    }
    final error = _error;
    if (error != null) {
      return _centered(
        topInset,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: colors.error),
              const SizedBox(height: 12),
              Text(
                context.l10n.filesOpenFolderError,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                error,
                style: TextStyle(color: colors.dim, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FaButton(
                variant: FaButtonVariant.secondary,
                icon: Icons.refresh,
                label: context.l10n.filesRetryButton,
                onPressed: _load,
              ),
            ],
          ),
        ),
      );
    }
    final entries = _entries!;
    if (entries.isEmpty) {
      return _centered(
        topInset,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 40, color: colors.dim),
            const SizedBox(height: 12),
            Text(
              context.l10n.filesEmptyFolder,
              style: TextStyle(color: colors.dim, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final query = _search.text.trim().toLowerCase();
    final visible = query.isEmpty
        ? entries
        : entries
              .where((entry) => entry.name.toLowerCase().contains(query))
              .toList(growable: false);
    if (visible.isEmpty) {
      return _centered(
        topInset,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 40, color: colors.dim),
            const SizedBox(height: 12),
            Text(
              context.l10n.filesNoSearchMatches,
              style: TextStyle(color: colors.dim, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final directories = visible
        .where((entry) => entry.kind == FileKind.directory)
        .toList(growable: false);
    final files = visible
        .where((entry) => entry.kind != FileKind.directory)
        .toList(growable: false);
    return ListView(
      key: const ValueKey('fileBrowserListing'),
      padding: EdgeInsets.fromLTRB(0, topInset + 4, 0, 12),
      children: [
        if (directories.isNotEmpty) ...[
          FaSectionEyebrow(
            key: const ValueKey('fileBrowserFoldersCard'),
            label: context.l10n.filesFoldersSection,
          ),
          for (final entry in directories) _entryRow(context, entry),
        ],
        if (files.isNotEmpty) ...[
          FaSectionEyebrow(
            key: const ValueKey('fileBrowserFilesCard'),
            label: context.l10n.filesFilesSection,
          ),
          for (final entry in files) _entryRow(context, entry),
        ],
      ],
    );
  }

  /// Centers [child] in the space below the chrome band ([topInset] down),
  /// the shared frame of the loading, error and empty states.
  Widget _centered(double topInset, {required Widget child}) => Padding(
    padding: EdgeInsets.only(top: topInset),
    child: Center(child: child),
  );

  /// The session-folder access gate (issue: Files showed the active
  /// mount for a session whose folder differs — a silent wrong listing).
  /// Names the session's folder and offers the existing security-scoped
  /// grant flow ([_grantSessionFolder]); declining keeps the gate.
  Widget _buildSessionFolderGate(BuildContext context, String folder) {
    final colors = FahColors.of(context);
    final name = folder.split('/').where((s) => s.isNotEmpty).lastOrNull;
    return Center(
      child: Padding(
        key: const ValueKey('filesSessionFolderGate'),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 40, color: colors.dim),
            const SizedBox(height: 12),
            Text(
              context.l10n.filesSessionFolderGateTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.filesSessionFolderGateBody(name ?? folder),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.dim, fontSize: 12),
            ),
            const SizedBox(height: 16),
            FaButton(
              key: const ValueKey('filesSessionFolderGateAllow'),
              variant: FaButtonVariant.secondary,
              icon: Icons.folder_open_outlined,
              label: context.l10n.filesSessionFolderGateAllow,
              onPressed: _grantSessionFolder,
            ),
          ],
        ),
      ),
    );
  }

  /// The inline preview's back bar, swapped into the chrome band in place
  /// of the path bar while a preview is open (one row of chrome, not two).
  Widget _buildPreviewBar(BuildContext context) {
    final colors = FahColors.of(context);
    final preview = _preview!;
    return SizedBox(
      key: const ValueKey('filePreviewHeader'),
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            _chromeIconButton(
              icon: Icons.arrow_back,
              tooltip: context.l10n.filesBackTooltip,
              onPressed: () => setState(() => _preview = null),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                preview.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One file row at chat-list density: a 12px-rounded transparent row
  /// (panelAlt on hover) with 10px content insets, instead of a ListTile
  /// inside a slab card.
  Widget _entryRow(BuildContext context, FileInfo entry) {
    final colors = FahColors.of(context);
    final isDir = entry.kind == FileKind.directory;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        key: ValueKey('fileRow-${entry.name}'),
        color: Colors.transparent,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => isDir ? _enterDir(entry) : _openFile(entry),
          borderRadius: BorderRadius.circular(12),
          hoverColor: colors.panelAlt,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: isDir
                        ? colors.indigo.withValues(alpha: .14)
                        : colors.panelAlt,
                    borderRadius: BorderRadius.circular(isDir ? 10 : 17),
                  ),
                  child: Icon(
                    _iconFor(entry),
                    size: 18,
                    color: isDir ? colors.indigo : colors.dim,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (isDir)
                  Icon(Icons.chevron_right, size: 18, color: colors.dim)
                else
                  Text(
                    formatFileSize(entry.size),
                    maxLines: 1,
                    style: TextStyle(color: colors.dim, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One circular chrome action for standalone Files controls (the close
/// button and path/preview navigation) — a thin delegate to the fa_ui
/// styleguide's [FaIconActionButton] (36pt composer scale, token
/// fill/hairline/ink). Adjacent browser actions use [FaIconActionBand]
/// instead, so they share one capsule rather than individual circles.
///
/// [buttonKey] lands on the inner button — the keyed widget sits INSIDE
/// its circular chrome (exactly where the pre-band header keyed its bar
/// buttons) and stays a single finder match.
final class FilesCircleAction extends StatelessWidget {
  const FilesCircleAction({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 36,
  }) : assert(size >= 32);

  final Key? buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// The circle's edge (composer scale by default).
  final double size;

  @override
  Widget build(BuildContext context) => FaIconActionButton(
    diameter: size,
    buttonKey: buttonKey,
    icon: icon,
    tooltip: tooltip,
    onPressed: onPressed,
    // The band provides its own surface: the flat token state.
    glass: false,
  );
}

/// The ONE Files chrome band — the native twin of the presented Files
/// pane's band, shared by every Files surface: the browser's own header
/// ([FileBrowser.showHeader]) and the presented/pushed/docked panes.
///
/// Layout: the close circle (the panel's own X) + the live search
/// capsule ([FaTextField]) + the browser actions. The X sits immediately
/// LEFT of the capsule — the collapse/expand morph: the same button flips
/// to an X next to "search files" while the panel is open, and the
/// header's folder icon only toggles. The capsule is the band's flexible
/// middle: it EXPANDS to fill everything between its neighbors (defect:
/// a fixed ~140px capsule). Fit policy, widest-first:
///  - roomy bands (≥ [kFilesSearchDesktopMin] after the close circle)
///    keep that desktop capsule minimum: actions demote tail-first into
///    a ⋮ menu, and the ⋮ itself yields before the minimum does;
///  - the title (and its folder glyph) shows only out of the surplus
///    beyond the active minimum, so a tight band is a wide capsule, not
///    a squeezed label;
///  - cramped bands (a resizable panel at its minimum) drop the actions
///    entirely and fill with the capsule ([kFilesSearchCompactFloor]).
///
/// The closing hairline comes from the browser's chrome stack below, so
/// the band paints no second divider.
final class FilesChrome extends StatelessWidget {
  const FilesChrome({
    super.key,
    required this.searchController,
    this.searchFocusNode,
    this.searchCollapsed = false,
    this.onSearchReveal,
    this.onSearchClose,
    this.actions = const <FaHeaderAction>[],
    this.onClose,
    this.closeKey,
    this.searchKey,
    this.overflowKey,
    this.menuColor,
    this.topCenterline = false,
  });

  /// The live filter the capsule types into (the browser's search state).
  final TextEditingController searchController;
  final FocusNode? searchFocusNode;

  /// Compact hosts collapse to a reveal action until search is active.
  final bool searchCollapsed;
  final VoidCallback? onSearchReveal;
  final VoidCallback? onSearchClose;

  /// The browser actions (refresh, upload, iCloud sync, mount), in
  /// priority order — the tail demotes into the ⋮ menu first.
  final List<FaHeaderAction> actions;

  /// Close circle — the panel's own X, rendered immediately LEFT of the
  /// search capsule; null hides it (hosts that toggle the surface
  /// themselves).
  final VoidCallback? onClose;

  /// Lookup keys for the capsule / close / ⋮ slots (tests and goldens).
  final Key? closeKey;
  final Key? searchKey;
  final Key? overflowKey;

  /// The ⋮ menu's background color (the browser passes its tokens).
  final Color? menuColor;

  /// Vertically biases the band's circles UP 4pt: the docked Files panel
  /// (right of the chat) must land the X's center on the header band's
  /// shared action centerline — the sidebar collapse toggle's center
  /// (screen y=35 in the docked panel). Standalone bands (the pipeline
  /// golden fixture, the narrow route) keep the symmetric centering.
  final bool topCenterline;

  static const _bandHeight = 52.0;

  /// The X's left inset: ~4pt from the band's left edge — the panel's own
  /// toggle hugs its panel (a 10pt inset read as a detached second header,
  /// not part of the panel). Vertical: symmetric 6s by default; the
  /// [topCenterline] docked variant trades 4pt of top inset (2 vs 6) so
  /// the circle's center rides the header band's shared action centerline.
  EdgeInsetsGeometry get _bandPadding => topCenterline
      ? const EdgeInsets.fromLTRB(4, 2, 10, 6)
      : const EdgeInsets.fromLTRB(4, 6, 10, 6);

  static const _titleIcon = 16.0;
  static const _titleGap = 7.0;
  static const _searchLeadingGap = 10.0;
  static const _searchTrailingGap = 8.0;
  static const _actionSlot = 36.0;
  static const _actionGap = 8.0;

  /// Icon + gap + the title-to-X air that only render alongside the
  /// title.
  static const double _titleExtras = _titleIcon + _titleGap + _searchLeadingGap;

  /// The desktop capsule minimum — the promise that the search field
  /// expands to a real field on roomy surfaces instead of a ~140px stub.
  static const double kFilesSearchDesktopMin = 220;

  /// The cramped-band floor: below the desktop minimum the capsule still
  /// takes the whole band, and only a band leaving this much shows a
  /// title at all.
  static const double kFilesSearchCompactFloor = 160;

  /// Minimum width the title text needs before it is worth showing.
  static const double _titleMin = 44;

  /// The field's hard floor: the glass kit's search chip (~44pt) plus the
  /// air the row needs to lay it out without overflow.
  static const double _fieldChipMin = 48;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return SizedBox(
      height: _bandHeight,
      child: Padding(
        padding: _bandPadding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            // No leading gap is reserved before the X: the toggle hugs
            // the band's 4pt inset ([_bandPadding]); the X-to-capsule gap
            // is the action gap, and the title's trailing air lives in
            // [_titleExtras].
            double budget({required int inline, required bool overflow}) {
              var w = _searchTrailingGap;
              final bandActions = inline + (overflow ? 1 : 0);
              // The inline actions and overflow share one capsule: no
              // per-action gap, just the band's 2pt inset on either side.
              if (bandActions > 0) w += bandActions * _actionSlot + 4;
              if (onClose != null) w += _actionGap + _actionSlot;
              if (onSearchClose != null) w += _actionGap + _actionSlot;
              return width - w;
            }

            // The capsule's promise on this band: a roomy one keeps the
            // desktop minimum for the field itself, a cramped one the
            // compact floor, a tiny one just fills.
            final bare = budget(inline: 0, overflow: false);
            final searchFloor = bare >= kFilesSearchDesktopMin
                ? kFilesSearchDesktopMin
                : bare >= kFilesSearchCompactFloor
                ? kFilesSearchCompactFloor
                : 0.0;
            // The one search field is the glass kit's GlassTextField: its
            // chip owns a ~44pt internal minimum (icon row + paddings) and
            // OVERFLOWS when squeezed under it. The capsule's promise
            // floors at the compact band, but the demotion must also hold
            // on tiny bands (reveal first frames, narrow windows) where
            // even the compact floor is unreachable — there the field
            // keeps the chip minimum and the chrome demotes instead.
            final fieldFloor = math.max(searchFloor, _fieldChipMin);
            // Actions demote tail-first while they would bite into the
            // capsule's promise; the ⋮ menu lives on the compact floor so
            // the actions stay reachable on middle-width bands. Anything
            // demoted at all keeps the ⋮ visible — the actions must stay
            // reachable even on bands where the floor itself is
            // unreachable.
            var inline = actions.length;
            while (inline > 0 &&
                budget(inline: inline, overflow: true) < fieldFloor) {
              inline--;
            }
            final overflow = inline < actions.length;
            final titleBudget =
                budget(inline: inline, overflow: overflow) -
                _titleExtras -
                searchFloor;
            final showTitle = titleBudget >= _titleMin;
            final demoted = [
              for (var i = inline; i < actions.length; i++) actions[i],
            ];
            return Row(
              children: [
                if (showTitle) ...[
                  Icon(
                    Icons.folder_open_outlined,
                    size: _titleIcon,
                    color: colors.dim,
                  ),
                  const SizedBox(width: _titleGap),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: titleBudget),
                    child: Text(
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
                  ),
                  // The title-to-X air only renders alongside the
                  // title: without it the X hugs the band's 4pt inset.
                  const SizedBox(width: _searchLeadingGap),
                ],
                // The panel's own X leads the capsule: the visible
                // close affordance, morphing in next to "search files"
                // while the panel is open.
                if (onClose != null) ...[
                  FilesCircleAction(
                    buttonKey: closeKey ?? const ValueKey('filesAppClose'),
                    icon: Icons.close,
                    tooltip: context.l10n.filesCloseTooltip,
                    onPressed: onClose,
                  ),
                  const SizedBox(width: _actionGap),
                ],
                // THE one search field (SessionSearchField): the same
                // dense sidebar-search inset the chats/activity/apps
                // headers render — the old sidebar look, NOT a taller
                // Files-specific capsule. The browser filters from its
                // own controller listener.
                if (searchCollapsed)
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FaIconActionButton(
                        buttonKey: const ValueKey('fileBrowserSearchReveal'),
                        onPressed: onSearchReveal,
                        tooltip: context.l10n.filesSearchHint,
                        diameter: 32,
                        glyphSize: 21,
                        glass: false,
                        child: const FaIcon(FaSemanticIcon.search),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: SessionSearchField(
                      key: searchKey ?? const ValueKey('fileBrowserSearch'),
                      controller: searchController,
                      focusNode: searchFocusNode,
                      hintText: context.l10n.filesSearchHint,
                    ),
                  ),
                if (onSearchClose != null) ...[
                  const SizedBox(width: _actionGap),
                  FaIconActionButton(
                    buttonKey: const ValueKey('fileBrowserSearchClose'),
                    onPressed: onSearchClose,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    diameter: 32,
                    glyphSize: 22,
                    glass: false,
                    child: const FaIcon(FaSemanticIcon.back),
                  ),
                ],
                const SizedBox(width: _searchTrailingGap),
                if (inline > 0 || overflow)
                  _actionBand(context, [
                    for (var i = 0; i < inline; i++) actions[i],
                  ], overflow ? demoted : const <FaHeaderAction>[]),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Browser actions and their demoted tail share the same single-capsule
  /// chrome as presented apps. The close control stays on the other side of
  /// the search field because it belongs to the panel, not this action group.
  Widget _actionBand(
    BuildContext context,
    List<FaHeaderAction> inline,
    List<FaHeaderAction> demoted,
  ) => FaIconActionBand<int>(
    key: const ValueKey('filesChromeActions'),
    actions: inline,
    menuColor: menuColor,
    overflowMenuKey: overflowKey ?? const ValueKey('fileBrowserOverflow'),
    overflowTooltip: FaChatStrings.of(context).chatMoreTooltip,
    overflowItems: [
      for (var i = 0; i < demoted.length; i++)
        PopupMenuItem(
          value: i,
          child: Row(
            children: [
              Icon(demoted[i].icon, size: 18),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  demoted[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ],
    onOverflowSelected: (index) => demoted[index].onPressed?.call(),
  );
}
