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
              onPressed: () => launchUrl(
                docs,
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(l10n.settingsCompactionDocs),
            ),
          ),
      ],
    );
  }
}
