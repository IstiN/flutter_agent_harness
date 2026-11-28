// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/context_window_config.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The context-window settings surfaces (gh-2479): the per-model display +
/// override row in the provider/model settings and the owner-cap control
/// in the Agent Config section. Both read and write the SAME config keys
/// the CLI does (`models.overrides` / `agent.contextWindowCap`) — single
/// source of truth, no app-only fork.

/// `1048576` → `1,048,576` (the provenance captions use the ticket's
/// grouped form; a plain integer is unreadable at a million tokens).
String formatTokenNumber(int tokens) {
  final digits = tokens.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    buffer.write(digits[i]);
    if ((digits.length - i - 1) % 3 == 0 &&
        i < digits.length - 1) {
      buffer.write(',');
    }
  }
  return digits.startsWith('-') ? '-${buffer.toString().substring(1)}' : '$buffer';
}

/// The source-layer caption for a resolved window (gh-2479): the labels
/// mirror capability_resolver.dart's precedence docs.
String contextWindowSourceLabel(
  CapabilityWindowLayer source,
  AppLocalizations l10n,
) => switch (source) {
  CapabilityWindowLayer.override => l10n.settingsWindowSourceOverride,
  CapabilityWindowLayer.roleSlot => l10n.settingsWindowSourceRoleChain,
  CapabilityWindowLayer.endpoint => l10n.settingsWindowSourceEndpoint,
  CapabilityWindowLayer.remoteCatalog => l10n.settingsWindowSourceRemoteCatalog,
  CapabilityWindowLayer.spec => l10n.settingsWindowSourceCatalog,
  CapabilityWindowLayer.unknownDefault => l10n.settingsWindowSourceDefault,
};

/// The per-model context-window display + override row: the effective
/// window with its source layer ("1,048,576 · endpoint report"), the
/// editable override (empty = inherit the chain) and the owner-cap note
/// when the cap replaced the number. Persisted to
/// `models.overrides.<provider>.<modelId>.contextWindow` in the USER
/// config — the same key the CLI's model-caps flow pins.
class ModelContextWindowSection extends StatefulWidget {
  const ModelContextWindowSection({
    super.key,
    required this.service,
    this.readOverride,
    this.write,
    this.supported = appContextWindowConfigSupported,
  });

  /// The live service: its active model supplies the identity and the
  /// resolved provenance; its [AgentService.applyModelWindowOverride]
  /// seam applies edits live.
  final AgentService service;

  /// Read seam (tests): the pinned override window; null = the chain.
  /// Defaults to the user-config read.
  final int? Function()? readOverride;

  /// Write seam (tests): persist the override (null clears it) and return
  /// the edited file path. Defaults to the validated user-config write;
  /// a throw surfaces verbatim (the file is never half-edited).
  final Future<String> Function(String provider, String modelId, int? window)?
  write;

  /// Whether this platform can persist the value (false on web).
  final bool supported;

  @override
  State<ModelContextWindowSection> createState() =>
      _ModelContextWindowSectionState();
}

class _ModelContextWindowSectionState extends State<ModelContextWindowSection> {
  late final TextEditingController _override;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _override = TextEditingController(text: _seed());
  }

  @override
  void dispose() {
    _override.dispose();
    super.dispose();
  }

  /// The field seed: the pinned override, else empty (inherit).
  String _seed() {
    final pinned = widget.readOverride?.call();
    return pinned == null ? '' : '$pinned';
  }

  Future<void> _save() async {
    if (_busy) return;
    final text = _override.text.trim();
    final provider = widget.service.providerKind;
    final modelId = widget.service.agentModelId;
    final int? value;
    if (text.isEmpty) {
      value = null;
    } else {
      final parsed = int.tryParse(text);
      if (parsed == null || parsed <= 0) {
        _showError(context.l10n.settingsContextWindowInvalid);
        return;
      }
      if (parsed < appMinOverrideContextWindow) {
        _showError(
          context.l10n.settingsContextWindowMinValue(
            '$appMinOverrideContextWindow',
          ),
        );
        return;
      }
      value = parsed;
    }
    setState(() => _busy = true);
    try {
      final file = await (widget.write ?? _defaultWrite)(provider, modelId, value);
      widget.service.applyModelWindowOverride(provider, modelId);
      if (!mounted) return;
      faui.showFahSnack(
        context,
        value == null
            ? context.l10n.settingsContextWindowCleared
            : context.l10n.settingsContextWindowSaved(file),
        duration: const Duration(seconds: 4),
      );
    } on Object catch (error) {
      if (!mounted) return;
      _showError(context.l10n.settingsContextWindowSaveFailed('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _defaultWrite(String provider, String modelId, int? value) =>
      writeAppModelWindowOverride(provider, modelId, value);

  void _showError(String message) {
    if (!mounted) return;
    faui.showFahErrorSnack(context, message, duration: const Duration(seconds: 6));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = faui.FaDesignTokens.of(context);
    final l10n = context.l10n;
    final provenance = widget.service.modelContextWindow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.settingsContextWindowLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (!widget.supported)
          Text(
            l10n.settingsContextCapWebNote,
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.ink2),
          )
        else ...[
          if (provenance == null)
            Text(
              l10n.settingsContextCapUnset,
              style: theme.textTheme.bodySmall?.copyWith(color: tokens.ink2),
            )
          else ...[
            Text(
              '${formatTokenNumber(provenance.window)} · '
                  '${contextWindowSourceLabel(provenance.source, l10n)}',
              style: theme.textTheme.bodyMedium,
            ),
            if (provenance.window != provenance.uncapped)
              Text(
                l10n.settingsContextWindowCapped('${provenance.cap}'),
                style: theme.textTheme.bodySmall?.copyWith(color: tokens.ink2),
              ),
          ],
          const SizedBox(height: 8),
          Text(l10n.settingsContextWindowOverrideLabel,
              style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('contextWindowOverrideField'),
            controller: _override,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              isDense: true,
              hintText: l10n.settingsContextWindowOverrideHelper,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              faui.FaButton(
                label: l10n.settingsSaveButton,
                variant: faui.FaButtonVariant.primary,
                onPressed: _busy ? null : _save,
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text(
          l10n.settingsContextWindowOverrideHelper,
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.ink2),
        ),
      ],
    );
  }
}

/// The owner context-window cap control (`agent.contextWindowCap`) in the
/// Agent Config settings: the effective value with its config layer, the
/// semantics helper (compaction thresholds / ctx meter / over-window
/// guard, applied AFTER the per-model chain) and set/clear actions — the
/// same validated surgical edits the CLI's context-cap flow makes.
class ContextWindowCapSection extends StatefulWidget {
  const ContextWindowCapSection({
    super.key,
    this.service,
    this.projectDir,
    this.resolve,
    this.write,
    this.apply,
    this.supported = appContextWindowConfigSupported,
  });

  /// The live service whose [AgentService.applyContextWindowCap] seam
  /// re-caps live after a persisted write; null (bare-section tests)
  /// keeps the write persistence-only.
  final AgentService? service;

  /// The session's project directory — the `<dir>/.fah/config.yaml` layer
  /// the resolution reads first and a fresh choice writes to.
  final String? projectDir;

  /// Resolution seam (tests inject a fake; default: the config loader).
  final AppContextCapResolution Function({String? projectDir, String? homeDir})?
  resolve;

  /// Write seam (tests inject a fake; default: the config writer).
  final Future<String> Function(
    int? value, {
    required AppContextCapSource layer,
    String? projectDir,
    String? homeDir,
  })?
  write;

  /// In-memory apply seam (tests; default: the service's live re-cap).
  final void Function(int? cap)? apply;

  /// Whether this platform can persist the choice (false on web).
  final bool supported;

  @override
  State<ContextWindowCapSection> createState() =>
      _ContextWindowCapSectionState();
}

class _ContextWindowCapSectionState extends State<ContextWindowCapSection> {
  AppContextCapResolution? _resolution;
  late final TextEditingController _cap;

  @override
  void initState() {
    super.initState();
    _cap = TextEditingController();
    _reload();
  }

  @override
  void didUpdateWidget(ContextWindowCapSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectDir != widget.projectDir) _reload();
  }

  @override
  void dispose() {
    _cap.dispose();
    super.dispose();
  }

  void _reload() {
    _resolution = (widget.resolve ?? resolveAppContextWindowCap)(
      projectDir: widget.projectDir,
    );
    _cap.text = _resolution?.cap == null ? '' : '${_resolution!.cap}';
  }

  /// The layer a new choice is written to: the layer that currently wins
  /// (an explicit choice is edited in place, never shadowed), else the
  /// project layer when a session dir exists (the compaction rule), else
  /// the user file.
  AppContextCapSource get _writeLayer {
    switch (_resolution?.source) {
      case AppContextCapSource.user:
        return AppContextCapSource.user;
      case AppContextCapSource.project:
        return AppContextCapSource.project;
      case null:
      case AppContextCapSource.none:
        return widget.projectDir != null
            ? AppContextCapSource.project
            : AppContextCapSource.user;
    }
  }

  Future<void> _onSave(int? value) async {
    try {
      final file = await (widget.write ?? _defaultWrite)(
        value,
        layer: _writeLayer,
        projectDir: widget.projectDir,
      );
      (widget.apply ?? widget.service?.applyContextWindowCap)?.call(value);
      if (!mounted) return;
      _reload();
      faui.showFahSnack(
        context,
        context.l10n.settingsContextWindowSaved(file),
        duration: const Duration(seconds: 4),
      );
    } on Object catch (error) {
      if (!mounted) return;
      faui.showFahErrorSnack(
        context,
        context.l10n.settingsContextWindowSaveFailed('$error'),
        duration: const Duration(seconds: 6),
      );
    }
  }

  Future<String> _defaultWrite(
    int? value, {
    required AppContextCapSource layer,
    String? projectDir,
    String? homeDir,
  }) => writeAppContextWindowCap(
    value,
    layer: layer,
    projectDir: projectDir,
    homeDir: homeDir,
  );

  int? _parsed() {
    final text = _cap.text.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = faui.FaDesignTokens.of(context);
    final l10n = context.l10n;
    final resolution = _resolution;
    if (!widget.supported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.settingsContextCapLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            l10n.settingsContextCapWebNote,
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.ink2),
          ),
        ],
      );
    }
    final sourceCaption = switch (resolution?.source) {
      AppContextCapSource.project => l10n.settingsCompactionSourceProject,
      AppContextCapSource.user => l10n.settingsCompactionSourceUser,
      _ => l10n.settingsContextCapUnset,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.settingsContextCapLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          l10n.settingsContextCapHelper,
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.ink2),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('contextWindowCapField'),
          controller: _cap,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            isDense: true,
            hintText: l10n.settingsContextCapUnset,
          ),
        ),
        const SizedBox(height: 8),
        Text(sourceCaption, style: theme.textTheme.bodySmall?.copyWith(color: tokens.ink2)),
        const SizedBox(height: 8),
        Row(
          children: [
            faui.FaButton(
              label: l10n.settingsSaveButton,
              variant: faui.FaButtonVariant.primary,
              onPressed: () => _onSave(_parsed()),
            ),
            const SizedBox(width: 12),
            if (resolution?.cap != null)
              faui.FaButton(
                label: l10n.settingsContextCapClear,
                variant: faui.FaButtonVariant.ghost,
                onPressed: () => _onSave(null),
              ),
          ],
        ),
      ],
    );
  }
}
