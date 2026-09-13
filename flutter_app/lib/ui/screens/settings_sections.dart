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
