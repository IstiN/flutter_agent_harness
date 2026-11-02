import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/ui/widgets/file_preview.dart';
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
    this.inlinePreview = true,
    this.uploadPicker,
    this.iCloudSyncService,
    this.maxUploadBatchBytes = kMaxUploadBatchBytes,
    this.fsRevision,
    this.htmlPreviewBuilder,
    this.projectFolderOps,
    this.onProjectMountChanged,
  });

  /// The environment whose filesystem is browsed — the same instance the
  /// agent's tools use (see `AgentService.env`).
  final ExecutionEnv env;

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

  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  /// Current directory as segments relative to the env root (`[]` = root).
  final List<String> _segments = [];

  List<FileInfo>? _entries;
  String? _error;

  /// The mount env when the agent's env is one (desktop/macOS); null
  /// elsewhere (the open-folder control hides then). Looks through the
  /// [SecretsExecutionEnv] wrapper the agent service always puts around
  /// the shared env.
  ProjectMountEnv? get _mountEnv {
    var env = widget.env;
    if (env is SecretsExecutionEnv) env = env.delegate;
    return env is ProjectMountEnv ? env : null;
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
    _load();
  }

  @override
  void didUpdateWidget(FileBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fsRevision != widget.fsRevision) {
      oldWidget.fsRevision?.removeListener(_onFsRevision);
      widget.fsRevision?.addListener(_onFsRevision);
    }
  }

  @override
  void dispose() {
    widget.fsRevision?.removeListener(_onFsRevision);
    super.dispose();
  }

  /// Agent-side filesystem change ("hook"): reload the listing and force
  /// the open preview to re-read its file. Conservative — a bump does not
  /// say which file changed (`bash` can touch anything), and one extra
  /// listDir/read is cheap.
  void _onFsRevision() {
    if (_preview != null) _previewRevision++;
    _load();
  }

  /// Path of the current directory in the env namespace, relative to its
  /// working directory.
  String get _envPath => _segments.isEmpty ? '.' : _segments.join('/');

  String _childPath(String name) =>
      _segments.isEmpty ? name : '${_segments.join('/')}/$name';

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
    return Material(
      key: const ValueKey('fileBrowserPanel'),
      color: colors.panel,
      shape: Border(left: BorderSide(color: colors.border, width: .5)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          ?_buildMountIdentity(context),
          _buildPathBar(context),
          Divider(height: 1, color: colors.border.withValues(alpha: .55)),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _headerAction(Widget button) => FaHeaderCircularAction(child: button);

  Widget _buildHeader(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: FaAdaptiveHeader(
          key: const ValueKey('fileBrowserHeader'),
          leading: Icon(
            Icons.folder_open_outlined,
            size: 18,
            color: colors.dim,
          ),
          title: context.l10n.filesPanelTitle,
          titleStyle: TextStyle(
            color: colors.text,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
          actions: [
            ?_buildMountControl(context),
            if (_picker != null)
              FaHeaderAction(
                key: const ValueKey('fileBrowserUpload'),
                icon: Icons.upload_file,
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
            FaHeaderAction(
              key: const ValueKey('fileBrowserRefresh'),
              icon: Icons.refresh,
              label: context.l10n.filesRefreshTooltip,
              onPressed: _load,
            ),
          ],
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          actionGap: 8,
          overflowMenuKey: const ValueKey('fileBrowserOverflow'),
          menuColor: tokens.surface2,
          actionBuilder: (context, action, button) => _headerAction(button),
          overflowBuilder: (context, button) => _headerAction(button),
        ),
      ),
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
    final name = mountedPath.split('/').where((part) => part.isNotEmpty).last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Tooltip(
        message: mountedPath,
        child: Container(
          key: const ValueKey('fileBrowserMountIdentity'),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: colors.panelAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border.withValues(alpha: .55)),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 14, color: colors.dim),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.dim,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPathBar(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final colors = FahColors.of(context);
    return SizedBox(
      key: const ValueKey('fileBrowserPathBar'),
      height: 40,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 12, 2),
        child: Row(
          children: [
            FaSurface(
              glass: false,
              circular: true,
              color: tokens.surface1,
              child: SizedBox.square(
                dimension: 36,
                child: IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(36),
                    maximumSize: const Size.square(36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  tooltip: context.l10n.filesUpTooltip,
                  onPressed: _segments.isEmpty ? null : _goUp,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                key: const ValueKey('fileBrowserBreadcrumbChip'),
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: colors.panelAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colors.border.withValues(alpha: .5),
                  ),
                ),
                child: SingleChildScrollView(
                  key: const ValueKey('fileBrowserBreadcrumbs'),
                  scrollDirection: Axis.horizontal,
                  child: Row(children: _breadcrumbs(context)),
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
    Widget crumb(String label, int index, bool isCurrent) {
      final child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(
          label,
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

  Widget _buildBody(BuildContext context) {
    final colors = FahColors.of(context);
    final preview = _preview;
    if (preview != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('filePreviewHeader'),
            height: 44,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                children: [
                  _headerAction(
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(40),
                        maximumSize: const Size.square(40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      tooltip: context.l10n.filesBackTooltip,
                      onPressed: () => setState(() => _preview = null),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      preview.name,
                      maxLines: 1,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: colors.border.withValues(alpha: .55)),
          Expanded(
            child: ColoredBox(
              color: colors.panel,
              child: FilePreviewView(
                key: ValueKey('${preview.path}#$_previewRevision'),
                env: widget.env,
                path: preview.path,
                name: preview.name,
                htmlPreviewBuilder: widget.htmlPreviewBuilder,
              ),
            ),
          ),
        ],
      );
    }

    if (_loading) {
      return Center(child: CircularProgressIndicator(color: colors.indigo));
    }
    final error = _error;
    if (error != null) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 40,
                color: theme.colorScheme.error,
              ),
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
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(context.l10n.filesRetryButton),
              ),
            ],
          ),
        ),
      );
    }
    final entries = _entries!;
    if (entries.isEmpty) {
      return Center(
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
    final directories = entries
        .where((entry) => entry.kind == FileKind.directory)
        .toList(growable: false);
    final files = entries
        .where((entry) => entry.kind != FileKind.directory)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (directories.isNotEmpty)
          _entryCard(
            directories,
            colors,
            key: const ValueKey('fileBrowserFoldersCard'),
          ),
        if (files.isNotEmpty)
          _entryCard(
            files,
            colors,
            key: const ValueKey('fileBrowserFilesCard'),
          ),
      ],
    );
  }

  Widget _entryCard(
    List<FileInfo> entries,
    FahColors colors, {
    required Key key,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Material(
        key: key,
        color: colors.panelAlt,
        clipBehavior: Clip.antiAlias,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.border.withValues(alpha: .55)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < entries.length; index++) ...[
              _entryRow(entries[index], colors),
              if (index != entries.length - 1)
                Divider(
                  height: 1,
                  indent: 54,
                  endIndent: 12,
                  color: colors.border.withValues(alpha: .45),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _entryRow(FileInfo entry, FahColors colors) {
    final isDir = entry.kind == FileKind.directory;
    return SizedBox(
      height: 52,
      child: ListTile(
        key: ValueKey('fileRow-${entry.name}'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        horizontalTitleGap: 10,
        minLeadingWidth: 36,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        hoverColor: colors.panel.withValues(alpha: .7),
        selectedTileColor: colors.indigo.withValues(alpha: .12),
        splashColor: colors.indigo.withValues(alpha: .12),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: colors.panel,
            borderRadius: BorderRadius.circular(isDir ? 10 : 18),
          ),
          child: Icon(_iconFor(entry), size: 18, color: colors.dim),
        ),
        title: Text(
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
        trailing: isDir
            ? Icon(Icons.chevron_right, size: 18, color: colors.dim)
            : Text(
                formatFileSize(entry.size),
                maxLines: 1,
                style: TextStyle(color: colors.dim, fontSize: 11),
              ),
        onTap: () => isDir ? _enterDir(entry) : _openFile(entry),
      ),
    );
  }
}
