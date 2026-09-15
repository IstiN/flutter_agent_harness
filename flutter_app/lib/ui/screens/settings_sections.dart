// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'settings.dart';

/// The settings "Theme" section: a dropdown over [FahThemeMode] bound to the
/// app-wide [ThemeController] (explicit [controller], else the nearest
/// [FahThemeScope]). Hidden when no controller is available (tests pumping
/// the bare form).
class ThemeModeSection extends StatelessWidget {
  const ThemeModeSection({super.key, this.controller});

  /// Controller override; falls back to the nearest [FahThemeScope].
  final ThemeController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = this.controller ?? FahThemeScope.maybeOf(context);
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.settingsThemeLabel,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<FahThemeMode>(
              // The key forces the FormField to re-seed when the mode is
              // changed from elsewhere.
              key: ValueKey<FahThemeMode>(controller.mode),
              initialValue: controller.mode,
              isExpanded: true,
              items: [
                DropdownMenuItem(
                  value: FahThemeMode.system,
                  child: Text(context.l10n.settingsThemeSystem),
                ),
                DropdownMenuItem(
                  value: FahThemeMode.light,
                  child: Text(context.l10n.settingsThemeLight),
                ),
                DropdownMenuItem(
                  value: FahThemeMode.dark,
                  child: Text(context.l10n.settingsThemeDark),
                ),
              ],
              onChanged: (mode) {
                if (mode != null) {
                  AppAnalytics.instance.themeChanged(mode.name);
                  controller.setMode(mode);
                }
              },
            ),
          ],
        );
      },
    );
  }
}

/// The settings "High-quality image previews" switch (issue #207): flips
/// the shared [ImagePreviewStore] (nearest [ImagePreviewScope]) — every
/// open transcript re-decodes its image previews immediately. Off (the
/// default) keeps the downscaled 600px previews. Hides without a store.
class ImagePreviewsSection extends StatelessWidget {
  const ImagePreviewsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final store = ImagePreviewScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return SwitchListTile(
          value: store.highQuality,
          onChanged: store.setHighQuality,
          title: Text(context.l10n.settingsImagePreviewsLabel),
          subtitle: Text(context.l10n.settingsImagePreviewsHelper),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
        );
      },
    );
  }
}

/// The settings "Theme packs" section (issue #169): the stock look plus
/// every installed pack as a radio group, `.zip` import through the
/// platform [UploadPicker], and per-pack removal. Removing the ACTIVE
/// pack reverts the app to the default look in the same tap. Hides when
/// the scopes are absent (tests pump the bare settings form).
class ThemePacksSection extends StatelessWidget {
  const ThemePacksSection({super.key, this.picker});

  /// File chooser for the `.zip` import; `null` falls back to the
  /// platform picker, which exists only on the web (the same contract as
  /// the attach sheet) — elsewhere the import button hides. Tests inject
  /// a fake.
  final UploadPicker? picker;

  Future<void> _import(BuildContext context, ThemePackStore store) async {
    final files =
        await (picker ?? createUploadPicker())?.pick() ?? const <UploadFile>[];
    if (files.isEmpty) return;
    final result = await store.installFromZip(files.first.bytes);
    if (!context.mounted) return;
    final l10n = context.l10n;
    final message = result.spec == null
        ? '${l10n.themePackImportFailed}:\n${result.reasons.join('\n')}'
        : result.warnings.isEmpty
        ? l10n.themePackImported(result.spec!.name)
        : '${l10n.themePackImported(result.spec!.name)}\n'
              '${result.warnings.join('\n')}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  Future<void> _remove(
    BuildContext context,
    ThemePackStore store,
    ThemeController controller,
    InstalledThemePack pack,
  ) async {
    await store.uninstall(pack.id);
    // The active choice reverts with the pack (never a dangling id).
    if (controller.packId == pack.id) {
      await controller.setPack(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = ThemePackScope.maybeOf(context);
    final controller = FahThemeScope.maybeOf(context);
    if (store == null || controller == null) return const SizedBox.shrink();
    final canPick = picker != null || createUploadPicker() != null;
    return ListenableBuilder(
      listenable: Listenable.merge([store, controller]),
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.themePacksTitle,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (canPick)
                  TextButton.icon(
                    onPressed: () => _import(context, store),
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: Text(context.l10n.themePackImport),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.themePacksSubtitle,
              style: theme.textTheme.bodySmall,
            ),
            RadioGroup<String?>(
              groupValue: controller.packId,
              onChanged: (id) => controller.setPack(
                id,
                hasWallpaper:
                    id != null && store.byId(id)?.spec.wallpaper != null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<String?>(
                    value: null,
                    title: Text(context.l10n.themePackDefault),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  for (final pack in store.packs)
                    RadioListTile<String?>(
                      key: ValueKey('theme-pack-${pack.id}'),
                      value: pack.id,
                      title: Text(pack.name),
                      subtitle:
                          (pack.spec.wallpaper == null &&
                              pack.spec.contrastWarnings.isEmpty)
                          ? null
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (pack.spec.wallpaper != null)
                                  Text(context.l10n.themePackWallpaperChip),
                                if (pack.spec.contrastWarnings.isNotEmpty)
                                  // The failing pairs (AC6), visible before
                                  // the radio apply — not just in the JS
                                  // consent dialog.
                                  Text(
                                    pack.spec.contrastWarnings.join(' · '),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                              ],
                            ),
                      secondary: IconButton(
                        tooltip: context.l10n.themePackDelete,
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () =>
                            _remove(context, store, controller, pack),
                      ),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The settings "Chat text size" section: a live slider over the shared
/// [ChatTextStore] (nearest [ChatTextScope]) — every open transcript
/// re-renders at the new size immediately. Hides without a store.
class ChatTextSection extends StatelessWidget {
  const ChatTextSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = ChatTextScope.maybeOf(context);
    if (store == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.settingsChatTextLabel,
              style: theme.textTheme.titleSmall,
            ),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: store.fontSize,
                    min: ChatTextStore.minFontSize,
                    max: ChatTextStore.maxFontSize,
                    divisions:
                        (ChatTextStore.maxFontSize - ChatTextStore.minFontSize)
                            .round(),
                    label: store.fontSize.toStringAsFixed(0),
                    onChanged: store.setFontSize,
                  ),
                ),
                SizedBox(
                  width: 32,
                  child: Text(
                    store.fontSize.toStringAsFixed(0),
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The settings "Compaction" section (issue #287): the engine picker —
/// structured (2.0, recommended) vs classic (legacy 1.0, the supported
/// rollback) — showing the CURRENT effective engine plus the config layer
/// it came from. Switching writes `compaction.engine` through the config
/// loader (a surgical yaml edit into the layer that currently wins —
/// never a whole-file rewrite) and takes effect at the NEXT compaction:
/// the per-compaction resolution in AgentService re-reads the chain
/// without a restart. On the web there is no config yaml — the picker is
/// disabled with a note and the structured default applies (AC5).
class CompactionSection extends StatefulWidget {
  const CompactionSection({
    super.key,
    this.projectDir,
    this.resolve,
    this.write,
    this.supported = appCompactionConfigSupported,
    this.docsUrl,
  });

  /// The session's project directory — the `<dir>/.fah/config.yaml` layer
  /// the loader reads first and the picker writes to by default.
  final String? projectDir;

  /// Resolution seam (tests inject a fake; default: the config loader).
  final AppCompactionEngineResolution Function({
    String? projectDir,
    String? homeDir,
  })?
  resolve;

  /// Writer seam (tests inject a fake; default: the config loader).
  final Future<String> Function(
    CompactionEngine engine, {
    required AppCompactionEngineSource layer,
    String? projectDir,
    String? homeDir,
  })?
  write;

  /// Whether this platform can persist the choice (false on web).
  final bool supported;

  /// Docs link under the picker (defaults to the repo's docs folder).
  final Uri? docsUrl;

  @override
  State<CompactionSection> createState() => _CompactionSectionState();
}

class _CompactionSectionState extends State<CompactionSection> {
  AppCompactionEngineResolution? _resolution;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(CompactionSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A session switch (different project dir) re-resolves.
    if (oldWidget.projectDir != widget.projectDir) _reload();
  }

  void _reload() {
    setState(() {
      _resolution = (widget.resolve ?? resolveAppCompactionEngine)(
        projectDir: widget.projectDir,
      );
    });
  }

  /// The layer a new choice is written to: the layer that currently wins
  /// (an explicit user choice is edited in place, never shadowed), else
  /// the project layer when one exists (mirrors `fa config set`'s scope),
  /// else the user file.
  AppCompactionEngineSource get _writeLayer {
    switch (_resolution?.source) {
      case AppCompactionEngineSource.user:
        return AppCompactionEngineSource.user;
      case AppCompactionEngineSource.project:
        return AppCompactionEngineSource.project;
      case null:
      case AppCompactionEngineSource.fallback:
        return widget.projectDir != null
            ? AppCompactionEngineSource.project
            : AppCompactionEngineSource.user;
    }
  }

  Future<void> _onEngineChanged(CompactionEngine? engine) async {
    if (engine == null || engine == _resolution?.engine) return;
    try {
      final file = await (widget.write ?? writeAppCompactionEngine)(
        engine,
        layer: _writeLayer,
        projectDir: widget.projectDir,
      );
      if (!mounted) return;
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.settingsCompactionSaved(file)),
          duration: const Duration(seconds: 4),
        ),
      );
    } on Object catch (error) {
      // A refused write (validation, no home dir) surfaces verbatim —
      // the config files are never left half-edited.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.settingsCompactionSaveFailed(error.toString()),
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final resolution = _resolution;
    if (!widget.supported) {
      // Web (AC5): no config yaml to read or write — show the effective
      // engine with the note instead of a picker that cannot persist.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.settingsCompactionLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            l10n.settingsCompactionWebNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    final engine = resolution?.engine ?? CompactionEngine.structured;
    final sourceCaption = switch (resolution?.source) {
      AppCompactionEngineSource.project => l10n.settingsCompactionSourceProject,
      AppCompactionEngineSource.user => l10n.settingsCompactionSourceUser,
      _ => l10n.settingsCompactionSourceFallback,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.settingsCompactionLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          l10n.settingsCompactionHelper,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<CompactionEngine>(
          // Re-seed when the effective engine changes elsewhere (config
          // edits apply without a restart — same trick as ThemeModeSection).
          key: ValueKey<CompactionEngine>(engine),
          initialValue: engine,
          isExpanded: true,
          items: [
            DropdownMenuItem(
              value: CompactionEngine.structured,
              child: Text(l10n.settingsCompactionStructured),
            ),
            DropdownMenuItem(
              value: CompactionEngine.classic,
              child: Text(l10n.settingsCompactionClassic),
            ),
          ],
          onChanged: _onEngineChanged,
        ),
        const SizedBox(height: 8),
        Text(
          engine == CompactionEngine.structured
              ? l10n.settingsCompactionStructuredHint
              : l10n.settingsCompactionClassicHint,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          sourceCaption,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (widget.docsUrl case final docs?)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  launchUrl(docs, mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(l10n.settingsCompactionDocs),
            ),
          ),
      ],
    );
  }
}

/// The settings "CLI-only" section (issue #288 AC4): settings the registry
/// classifies as CLI-only are listed here WITH their reason — never a
/// silent absence. The list and the justifications come straight from the
/// shared registry (`cliOnlySettings` + `cliOnlyJustifications`), so the
/// app cannot drift from the parity contract; only the labels are
/// localized (the reasons name host capabilities and stay verbatim).
class CliOnlySettingsSection extends StatelessWidget {
  const CliOnlySettingsSection({super.key});

  String _label(AppLocalizations l10n, SharedSetting setting) =>
      switch (setting) {
        SharedSetting.mcpServers => l10n.settingsCliOnlyMcpServers,
        SharedSetting.ttsrRules => l10n.settingsCliOnlyTtsrRules,
        SharedSetting.cubeSandbox => l10n.settingsCliOnlyCubeSandbox,
        SharedSetting.promptOverrides => l10n.settingsCliOnlyPromptOverrides,
        SharedSetting.agentMode => l10n.settingsCliOnlyAgentMode,
        SharedSetting.memoryStores => l10n.settingsCliOnlyMemoryStores,
        _ => setting.name,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          context.l10n.settingsCliOnlyTitle,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          context.l10n.settingsCliOnlyLead,
          style: TextStyle(
            color: theme.textTheme.bodySmall?.color,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        for (final setting in cliOnlySettings)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.terminal,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_label(context.l10n, setting)),
                      Text(
                        cliOnlyJustifications[setting] ?? '',
                        style: TextStyle(
                          color: theme.textTheme.bodySmall?.color,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The provider-queue editor (issue #418): the ordered main-model failover
/// chain (`providersQueue:`), the same entries the CLI's `/providers queue`
/// edits. Resolves through the CORE scope precedence — `FA_PROVIDERS_QUEUE`
/// env (read-only everywhere: a sandboxed UI cannot edit the environment)
/// > project `.fah/config.yaml` > user `~/.fah/config.yaml` — and writes are
/// surgical, whole-section-validated upserts, so an edit applies from the
/// next run without ever leaving a half-edited config behind.
class ProviderQueueSection extends StatefulWidget {
  const ProviderQueueSection({
    super.key,
    this.projectDir,
    this.resolve,
    this.write,
    this.supported = appProviderQueueConfigSupported,
  });

  /// The session's project directory — the `.fah/config.yaml` layer the
  /// boot reads before the user file.
  final String? projectDir;

  /// Resolution seam (tests inject a fake; default: the shared loader).
  final ProviderQueueResolution Function({String? projectDir, String? homeDir})?
  resolve;

  /// Writer seam (tests inject a fake; default: the shared loader).
  final Future<String> Function(
    List<ProviderQueueEntry> entries, {
    required ProviderQueueScope layer,
    String? projectDir,
    String? homeDir,
  })?
  write;

  /// Whether this platform can persist the queue (false on web).
  final bool supported;

  @override
  State<ProviderQueueSection> createState() => _ProviderQueueSectionState();
}

class _ProviderQueueSectionState extends State<ProviderQueueSection> {
  ProviderQueueResolution? _resolution;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(ProviderQueueSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A session switch (different project dir) re-resolves.
    if (oldWidget.projectDir != widget.projectDir) _reload();
  }

  void _reload() {
    setState(() {
      _resolution = (widget.resolve ?? resolveAppProviderQueue)(
        projectDir: widget.projectDir,
      );
    });
  }

  /// The scope a change is written to: the scope that currently wins
  /// (an explicit file choice is edited in place, never shadowed), else
  /// the project layer when one exists (mirrors the CLI editor's scope),
  /// else the user file.
  ProviderQueueScope get _writeScope {
    switch (_resolution?.scope) {
      case ProviderQueueScope.project:
        return ProviderQueueScope.project;
      case ProviderQueueScope.env:
      case ProviderQueueScope.user:
      case null:
        return widget.projectDir != null
            ? ProviderQueueScope.project
            : ProviderQueueScope.user;
    }
  }

  Future<void> _save(List<ProviderQueueEntry> entries) async {
    try {
      final file = await (widget.write ?? writeAppProviderQueue)(
        entries,
        layer: _writeScope,
        projectDir: widget.projectDir,
      );
      if (!mounted) return;
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.settingsQueueSaved(file)),
          duration: const Duration(seconds: 4),
        ),
      );
    } on Object catch (error) {
      // A refused write (env wins, validation) surfaces verbatim — the
      // config files are never left half-edited.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.settingsQueueSaveFailed(error.toString())),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _addEntry() async {
    final entry = await showDialog<ProviderQueueEntry>(
      context: context,
      builder: (context) => const _QueueEntryDialog(),
    );
    if (entry == null) return;
    _save([...?_resolution?.entries, entry]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    if (!widget.supported) {
      // Web: no config yaml to read or write — say so instead of an
      // editor that cannot persist.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.settingsQueueTitle, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(l10n.settingsQueueUnsupported),
        ],
      );
    }
    final resolution = _resolution;
    final entries = resolution?.entries ?? const [];
    final envWins = resolution?.scope == ProviderQueueScope.env;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.settingsQueueTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          l10n.settingsQueueHelper,
          style: TextStyle(
            color: theme.textTheme.bodySmall?.color,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        if (resolution == null || !resolution.isSet)
          Text(l10n.settingsQueueEmpty)
        else ...[
          for (final (index, entry) in entries.indexed)
            _QueueEntryTile(
              index: index,
              entry: entry,
              enabled: !envWins,
              onMoveUp: index == 0
                  ? null
                  : () => _save([
                      for (var i = 0; i < entries.length; i++)
                        if (i == index)
                          entries[index - 1]
                        else if (i == index - 1)
                          entries[index]
                        else
                          entries[i],
                    ]),
              onMoveDown: index == entries.length - 1
                  ? null
                  : () => _save([
                      for (var i = 0; i < entries.length; i++)
                        if (i == index)
                          entries[index + 1]
                        else if (i == index + 1)
                          entries[index]
                        else
                          entries[i],
                    ]),
              onRemove: () => _save([
                for (var i = 0; i < entries.length; i++)
                  if (i != index) entries[i],
              ]),
            ),
        ],
        if (envWins)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.settingsQueueScopeEnv,
              style: TextStyle(color: theme.colorScheme.tertiary, fontSize: 12),
            ),
          ),
        const SizedBox(height: 8),
        if (!envWins)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _addEntry,
              icon: const Icon(Icons.add),
              label: Text(l10n.settingsQueueAdd),
            ),
          ),
      ],
    );
  }
}

/// One queue row: position, provider type, model, key env — with
/// reorder/remove actions disabled when the env scope owns the queue.
class _QueueEntryTile extends StatelessWidget {
  const _QueueEntryTile({
    required this.index,
    required this.entry,
    required this.enabled,
    this.onMoveUp,
    this.onMoveDown,
    this.onRemove,
  });

  final int index;
  final ProviderQueueEntry entry;
  final bool enabled;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${index + 1}.',
              style: TextStyle(color: theme.textTheme.bodySmall?.color),
            ),
          ),
          Expanded(
            child: Text(
              '${entry.providerType} · ${entry.model}'
              '${entry.baseUrl == null ? '' : ' · ${entry.baseUrl}'}'
              '${entry.apiKeyEnv == null ? '' : ' · \$${entry.apiKeyEnv}'}',
            ),
          ),
          IconButton(
            tooltip: context.l10n.settingsQueueMoveUp,
            onPressed: enabled ? onMoveUp : null,
            icon: const Icon(Icons.arrow_upward, size: 18),
          ),
          IconButton(
            tooltip: context.l10n.settingsQueueMoveDown,
            onPressed: enabled ? onMoveDown : null,
            icon: const Icon(Icons.arrow_downward, size: 18),
          ),
          IconButton(
            tooltip: context.l10n.settingsQueueRemove,
            onPressed: enabled ? onRemove : null,
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }
}

/// The add-entry dialog: provider type, model, key env, optional base URL.
/// Validation runs through the REAL parser — the dialog only returns an
/// entry [parseProviderQueueJsonText] accepts.
class _QueueEntryDialog extends StatefulWidget {
  const _QueueEntryDialog();

  @override
  State<_QueueEntryDialog> createState() => _QueueEntryDialogState();
}

class _QueueEntryDialogState extends State<_QueueEntryDialog> {
  final _kind = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();
  final _url = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _kind.dispose();
    _model.dispose();
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final json = [
      {
        'provider_type': _kind.text.trim(),
        'provider_config': {
          'model': _model.text.trim(),
          if (_key.text.trim().isNotEmpty) 'apiKeyEnv': _key.text.trim(),
          if (_url.text.trim().isNotEmpty) 'baseUrl': _url.text.trim(),
        },
      },
    ];
    try {
      final parsed = parseProviderQueueJsonText(jsonEncode(json));
      final parsedEntries = parsed?.entries ?? const [];
      if (parsedEntries.isEmpty) {
        setState(() => _error = context.l10n.settingsQueueInvalid('empty'));
        return;
      }
      Navigator.of(context).pop(parsedEntries.single);
    } on Object catch (error) {
      setState(() => _error = context.l10n.settingsQueueInvalid('$error'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.settingsQueueAddTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _kind,
            decoration: InputDecoration(
              labelText: context.l10n.settingsQueueKind,
            ),
          ),
          TextField(
            controller: _model,
            decoration: InputDecoration(
              labelText: context.l10n.settingsQueueModel,
            ),
          ),
          TextField(
            controller: _key,
            decoration: InputDecoration(
              labelText: context.l10n.settingsQueueApiKeyEnv,
            ),
          ),
          TextField(
            controller: _url,
            decoration: InputDecoration(
              labelText: context.l10n.settingsQueueBaseUrl,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.settingsQueueCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(context.l10n.settingsQueueAddAction),
        ),
      ],
    );
  }
}
