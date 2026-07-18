import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'file_preview.dart';

/// Width of the file browser panel (side panel on wide layouts, drawer on
/// narrow ones).
const double kFileBrowserPanelWidth = 300;

/// Read-only file browser over the agent's [ExecutionEnv].
///
/// Folders navigate (breadcrumb + up), files open a preview — inline in the
/// panel when [inlinePreview] is true (wide layouts), or as a pushed
/// [FilePreviewScreen] route otherwise (narrow layouts).
///
/// Typed against the [ExecutionEnv] abstraction only, so a cloud-backed env
/// can drop in later without UI changes. Navigation uses paths relative to
/// the env's working directory (never [FileInfo.path]): relative paths
/// resolve against the sandbox root on every backend, whereas returned
/// absolute paths are not portable across envs (e.g. the mobile sandbox maps
/// `/`-rooted paths onto a host directory).
class FileBrowser extends StatefulWidget {
  const FileBrowser({super.key, required this.env, this.inlinePreview = true});

  /// The environment whose filesystem is browsed — the same instance the
  /// agent's tools use (see `AgentService.env`).
  final ExecutionEnv env;

  /// Whether file previews render inside the panel (true) or push a
  /// full-screen route (false).
  final bool inlinePreview;

  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  /// Current directory as segments relative to the env root (`[]` = root).
  final List<String> _segments = [];

  List<FileInfo>? _entries;
  String? _error;
  bool _loading = true;

  /// Inline preview target, when [FileBrowser.inlinePreview] is on.
  ({String path, String name})? _preview;

  @override
  void initState() {
    super.initState();
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
          _error = result.errorOrNull?.message ?? 'Could not list folder';
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
          builder: (_) =>
              FilePreviewScreen(env: widget.env, path: path, name: info.name),
        ),
      );
    }
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
          Expanded(child: Text('Files', style: theme.textTheme.titleMedium)),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  Widget _buildPathBar(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 18),
            tooltip: 'Up',
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
                tooltip: 'Back to files',
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
              key: ValueKey(preview.path),
              env: widget.env,
              path: preview.path,
              name: preview.name,
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
              Text('Could not open folder', style: theme.textTheme.titleSmall),
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
                label: const Text('Retry'),
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
            Text('Empty folder', style: theme.textTheme.bodySmall),
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
