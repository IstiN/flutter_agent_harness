part of 'wide_layout_shell.dart';

enum _NewSessionFolderAction { current, choose, sandbox }

final class _NewSessionFolderSelection {
  const _NewSessionFolderSelection(this.action, this.sessionName);

  final _NewSessionFolderAction action;
  final String? sessionName;
}

/// Folder choice plus an optional app-local title. Naming deliberately does
/// not create or rewrite the JSONL session: the existing names overlay owns
/// this metadata and blank input keeps the derived title.
final class _NewSessionFolderDialog extends StatefulWidget {
  const _NewSessionFolderDialog({required this.mountedPath});

  final String? mountedPath;

  @override
  State<_NewSessionFolderDialog> createState() =>
      _NewSessionFolderDialogState();
}

final class _NewSessionFolderDialogState
    extends State<_NewSessionFolderDialog> {
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _select(_NewSessionFolderAction action) {
    final name = _nameController.text.trim();
    Navigator.pop(
      context,
      _NewSessionFolderSelection(action, name.isEmpty ? null : name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mountedPath = widget.mountedPath;
    return SimpleDialog(
      title: Text(l10n.newSessionFolderTitle),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: TextField(
            key: const ValueKey('newSessionName'),
            controller: _nameController,
            autocorrect: false,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: l10n.sessionInfoNameLabel),
          ),
        ),
        SimpleDialogOption(
          key: const ValueKey('newSessionCurrentFolder'),
          onPressed: () => _select(_NewSessionFolderAction.current),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              mountedPath != null
                  ? l10n.newSessionCurrentFolder(p.basename(mountedPath))
                  : l10n.sessionFolderPersonal,
            ),
            subtitle: mountedPath != null ? Text(mountedPath) : null,
            leading: const Icon(Icons.folder_outlined),
          ),
        ),
        if (defaultProjectFolderOps() != null)
          SimpleDialogOption(
            key: const ValueKey('newSessionChooseFolder'),
            onPressed: () => _select(_NewSessionFolderAction.choose),
            child: ListTile(
              title: Text(l10n.newSessionChooseFolder),
              leading: const Icon(Icons.create_new_folder_outlined),
            ),
          ),
        if (mountedPath == null)
          SimpleDialogOption(
            key: const ValueKey('newSessionSandboxFolder'),
            onPressed: () => _select(_NewSessionFolderAction.sandbox),
            child: ListTile(
              title: Text(l10n.newSessionSandboxFolder),
              leading: const Icon(Icons.drive_file_rename_outline),
            ),
          ),
      ],
    );
  }
}

final class _NewSandboxFolderDialog extends StatefulWidget {
  const _NewSandboxFolderDialog();

  @override
  State<_NewSandboxFolderDialog> createState() =>
      _NewSandboxFolderDialogState();
}

final class _NewSandboxFolderDialogState
    extends State<_NewSandboxFolderDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    final name = value?.trim() ?? '';
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      return context.l10n.newSessionSandboxNameError;
    }
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.newSessionSandboxNameTitle),
      content: Form(
        key: _formKey,
        child: TextFormField(
          key: const ValueKey('newSessionSandboxName'),
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.newSessionSandboxNameLabel,
          ),
          validator: _validate,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('newSessionCreateSandboxFolder'),
          onPressed: _submit,
          child: Text(l10n.newSessionCreate),
        ),
      ],
    );
  }
}

/// Session creation semantics shared by narrow and wide shells.
extension _WideLayoutShellSessionActions on _WideLayoutShellState {
  /// A picked/current mount is the session's project. Without one, allocate
  /// a real per-chat sandbox directory instead of putting every Personal
  /// session in the same container root. The repository stays shared; only
  /// the cloned service's working environment is scoped to the new folder.
  Future<void> _createSessionInChosenFolder(
    AgentService service,
    AgentConfig config, {
    String? sandboxFolderName,
    String? sessionName,
  }) async {
    final FlutterManagedSession created;
    if (currentMountedPath(service.env) != null) {
      created = await widget.manager.createSession(
        config: config,
        serviceFactory: () async => service.clone(),
      );
    } else {
      final folder = p.join(
        service.env.cwd,
        'chats',
        sandboxFolderName ?? createSessionId(),
      );
      (await service.env.createDir(folder)).getOrThrow();
      final sessionEnv = CwdOverrideEnv(service.env)..cwd = folder;
      created = await widget.manager.createSession(
        config: config,
        serviceFactory: () async => service.clone(envOverride: sessionEnv),
      );
    }
    final title = sessionName?.trim() ?? '';
    if (title.isNotEmpty) {
      final names =
          widget.sessionNamesStore ?? _namesStore ?? service.namesStoreOverride;
      // Creation has already succeeded; title persistence is best-effort in
      // SessionNamesStore and never retries/clones a second session.
      await names?.rename(created.id, title);
    }
    if (mounted && _isNarrow) await _pushNarrowChat();
  }
}
