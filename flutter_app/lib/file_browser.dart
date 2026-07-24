import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'file_preview.dart';
import 'project_folder_channel.dart';
import 'project_mount_env.dart';
import 'project_mount_store.dart';
import 'upload.dart';
import 'upload_picker_stub.dart'
    if (dart.library.html) 'upload_picker_web.dart';

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
  /// elsewhere (the open-folder control hides then).
  ProjectMountEnv? get _mountEnv =>
      widget.env is ProjectMountEnv ? widget.env as ProjectMountEnv : null;

  Future<void> _pickProjectFolder() async {
    final mountEnv = _mountEnv;
    if (mountEnv == null) return;
    final ops = widget.projectFolderOps ?? _defaultProjectFolderOps();
    if (ops == null) return;
    final picked = await ops.pickDirectory();
    if (picked == null) return;
    final ok = await ops.startAccessing(picked.bookmark);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.filesFolderAccessDenied)),
        );
      }
      return;
    }
    await ProjectMountStore.save(
      widget.env,
      path: picked.path,
      bookmark: picked.bookmark,
    );
    setState(() {
      mountEnv.mountedRoot = picked.path;
      mountEnv.mountUnavailable = null;
    });
    widget.onProjectMountChanged?.call();
    await _load();
  }

  Future<void> _unmountProjectFolder() async {
    final mountEnv = _mountEnv;
    final root = mountEnv?.mountedRoot;
    if (mountEnv == null || root == null) return;
    final ops = widget.projectFolderOps ?? _defaultProjectFolderOps();
    final stored = await ProjectMountStore.load(widget.env);
    if (stored != null && ops != null) {
      await ops.stopAccessing(stored.bookmark);
    }
    await ProjectMountStore.clear(widget.env);
    setState(() => mountEnv.mountedRoot = null);
    widget.onProjectMountChanged?.call();
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

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// Picks files and writes them into the currently viewed folder of the
  /// sandbox filesystem, so the agent can work with them right away.
  Future<void> _upload() async {
    final picker = _picker;
    if (picker == null) return;
    final List<UploadFile> picked;
    try {
      picked = await picker.pick();
    } on Object catch (e) {
      if (mounted) _showSnack(context.l10n.filesUploadFailed(e.toString()));
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final sizeError = uploadBatchSizeError(
      picked,
      maxBytes: widget.maxUploadBatchBytes,
      message: (total, max) => context.l10n.uploadTooLarge(max, total),
    );
    if (sizeError != null) {
      _showSnack(sizeError);
      return;
    }

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
    if (!mounted) return;
    if (written > 0) await _load();
    if (!mounted) return;
    // Failures stay visible: which files, not just how many.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        _buildPathBar(context),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
      child: Row(
        children: [
          Icon(Icons.folder_open_outlined, size: 20, color: theme.hintColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.filesPanelTitle,
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (_buildMountControl(context) case final control?) control,
          if (_picker != null)
            IconButton(
              icon: const Icon(Icons.upload_file),
              tooltip: context.l10n.filesUploadTooltip,
              onPressed: _upload,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: context.l10n.filesRefreshTooltip,
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  /// The project-folder control for the header (macOS sandbox): an
  /// open-folder button when unmounted, a name+eject chip when mounted, a
  /// warning chip when the stored folder became unavailable. Null when the
  /// env has no mount support (web/mobile).
  Widget? _buildMountControl(BuildContext context) {
    final mountEnv = _mountEnv;
    if (mountEnv == null) return null;
    final unavailable = mountEnv.mountUnavailable;
    if (unavailable != null) {
      return IconButton(
        icon: Icon(
          Icons.warning_amber_outlined,
          color: Theme.of(context).colorScheme.error,
        ),
        tooltip: context.l10n.filesMountUnavailableTooltip(unavailable),
        onPressed: _pickProjectFolder,
      );
    }
    final mountedPath = mountEnv.mountedRoot;
    if (mountedPath != null) {
      final name = mountedPath.split('/').where((part) => part.isNotEmpty).last;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, style: Theme.of(context).textTheme.bodySmall),
          IconButton(
            icon: const Icon(Icons.eject_outlined),
            tooltip: context.l10n.filesUnmountTooltip(mountedPath),
            onPressed: _unmountProjectFolder,
          ),
        ],
      );
    }
    final canPick =
        widget.projectFolderOps != null || ProjectFolderChannelOps.isSupported;
    if (!canPick) return null;
    return IconButton(
      icon: const Icon(Icons.create_new_folder_outlined),
      tooltip: context.l10n.filesOpenProjectFolderTooltip,
      onPressed: _pickProjectFolder,
    );
  }

  Widget _buildPathBar(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 18),
            tooltip: context.l10n.filesUpTooltip,
            onPressed: _segments.isEmpty ? null : _goUp,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: _breadcrumbs(context)),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _breadcrumbs(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    Widget crumb(String label, int index, bool isCurrent) {
      final child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(
          label,
          style: isCurrent
              ? style?.copyWith(fontWeight: FontWeight.bold)
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
      crumbs.add(Icon(Icons.chevron_right, size: 14, color: theme.hintColor));
      crumbs.add(crumb(_segments[i], i, i == _segments.length - 1));
    }
    return crumbs;
  }

  Widget _buildBody(BuildContext context) {
    final preview = _preview;
    if (preview != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: context.l10n.filesBackTooltip,
                onPressed: () => setState(() => _preview = null),
              ),
              Expanded(
                child: Text(
                  preview.name,
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: FilePreviewView(
              key: ValueKey('${preview.path}#$_previewRevision'),
              env: widget.env,
              path: preview.path,
              name: preview.name,
              htmlPreviewBuilder: widget.htmlPreviewBuilder,
            ),
          ),
        ],
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
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
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                error,
                style: theme.textTheme.bodySmall,
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
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              context.l10n.filesEmptyFolder,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final isDir = entry.kind == FileKind.directory;
        return ListTile(
          dense: true,
          leading: Icon(_iconFor(entry), size: 20),
          title: Text(entry.name, overflow: TextOverflow.ellipsis),
          trailing: isDir
              ? const Icon(Icons.chevron_right, size: 18)
              : Text(
                  formatFileSize(entry.size),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
          onTap: () => isDir ? _enterDir(entry) : _openFile(entry),
        );
      },
    );
  }
}
