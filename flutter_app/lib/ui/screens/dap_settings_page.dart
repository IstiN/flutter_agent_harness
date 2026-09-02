// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/dap_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:flutter/material.dart';

/// The settings "DAP hub" row: opens the dedicated [DapHubPage] (connection,
/// identity, channels) so the top level stays provider-focused. The
/// connection is the machine-shared `~/.dap` config — the same one the CLI
/// agents read (docs/dap.md §9) — so the section is service-independent.
class DapHubSection extends StatelessWidget {
  const DapHubSection({super.key, this.service});

  /// Overrides the platform service (tests); defaults to the real one.
  final DapHubService? service;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        AppAnalytics.instance.dapHubAction('open');
        unawaited(faui.pushFaPage<void>(context, DapHubPage(service: service)));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.hub_outlined, size: 20, color: colors.dim),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.settingsDapHubTitle,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    context.l10n.settingsDapHubHint,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.dim),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: colors.dim),
          ],
        ),
      ),
    );
  }
}

/// The DAP hub settings page: the resolved hub URL with a live connection
/// probe, the agent name/agentId identity, the channels this machine holds
/// keys for, and the add/edit connection editor. On web (the hub client is
/// IO-bound) it renders the honest not-supported note instead.
class DapHubPage extends StatefulWidget {
  const DapHubPage({super.key, this.service});

  /// Overrides the platform service (tests); defaults to the real one.
  final DapHubService? service;

  @override
  State<DapHubPage> createState() => _DapHubPageState();
}

class _DapHubPageState extends State<DapHubPage> {
  late final DapHubService _service = widget.service ?? createDapHubService();
  DapHubSnapshot? _snapshot;
  var _probing = false;

  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.screenOpened('settings_dap_hub');
    _reload();
  }

  Future<void> _reload() async {
    final snapshot = await _service.load();
    if (mounted) setState(() => _snapshot = snapshot);
  }

  Future<void> _probe() async {
    if (_probing) return;
    setState(() => _probing = true);
    AppAnalytics.instance.dapHubAction('probe');
    try {
      final snapshot = await _service.probe();
      if (mounted) {
        setState(() {
          _snapshot = snapshot;
          _probing = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _edit() async {
    final snapshot = _snapshot;
    if (snapshot == null || !snapshot.supported) return;
    AppAnalytics.instance.dapHubAction('edit');
    final draft = await faui.pushFaPage<DapConnectionDraft>(
      context,
      DapConnectionEditorPage(
        initialUrl: snapshot.url,
        initialName: snapshot.name,
      ),
    );
    if (draft == null) return;
    await _service.saveConnection(url: draft.url, name: draft.name);
    AppAnalytics.instance.dapHubAction('save');
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: faAppBar(title: Text(context.l10n.settingsDapHubTitle)),
      body: snapshot == null
          ? const Center(child: CircularProgressIndicator())
          : snapshot.supported
          ? _connectionBody(context, snapshot)
          : _unsupportedBody(context),
    );
  }

  Widget _connectionBody(BuildContext context, DapHubSnapshot snapshot) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.settingsDapUrlLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.dim,
                        ),
                      ),
                      Text(
                        snapshot.url,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                    ],
                  ),
                ),
                _statusChip(context, snapshot),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _probing ? null : _probe,
                icon: _probing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: Text(context.l10n.settingsDapProbeButton),
              ),
            ),
            if (snapshot.envLocked) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.l10n.settingsDapEnvNote,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            _labeledRow(
              context,
              context.l10n.settingsDapAgentNameLabel,
              snapshot.name ?? '—',
            ),
            _labeledRow(
              context,
              context.l10n.settingsDapAgentIdLabel,
              snapshot.agentId ?? '—',
              mono: true,
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            Text(
              context.l10n.settingsDapChannelsTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (snapshot.channels.isEmpty)
              Text(
                context.l10n.settingsDapChannelsEmpty,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final channel in snapshot.channels)
                    Chip(
                      label: Text(
                        '#$channel', // l10n:ignore — channel name (data)
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: Text(context.l10n.settingsDapEditConnection),
            ),
          ],
        ),
      ),
    );
  }

  Widget _labeledRow(
    BuildContext context,
    String label,
    String value, {
    bool mono = false,
  }) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: mono ? 'JetBrainsMono' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(BuildContext context, DapHubSnapshot snapshot) {
    final theme = Theme.of(context);
    final (:icon, :label, :color) = switch (snapshot.connected) {
      null => (
        icon: Icons.help_outline,
        label: context.l10n.settingsDapStatusUnknown,
        color: FahColors.of(context).dim,
      ),
      true => (
        icon: Icons.check_circle_outline,
        label: context.l10n.settingsDapStatusConnected,
        color: theme.colorScheme.primary,
      ),
      false => (
        icon: Icons.cancel_outlined,
        label: context.l10n.settingsDapStatusOffline,
        color: theme.colorScheme.error,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }

  /// The platform-honest state: the hub client needs `dart:io` (WebSocket
  /// transport, `~/.dap` files), so on web there is nothing to configure.
  Widget _unsupportedBody(BuildContext context) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub_outlined, size: 40, color: colors.dim),
              const SizedBox(height: 12),
              Text(
                context.l10n.settingsDapUnsupported,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: colors.dim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The values collected by the [DapConnectionEditorPage].
final class DapConnectionDraft {
  const DapConnectionDraft({required this.url, required this.name});

  final String url;
  final String name;
}

/// The add/edit connection form (the provider-editor UX): hub URL and agent
/// name, saved to the machine-shared `~/.dap/config.json` by [DapHubPage].
/// Pops with a [DapConnectionDraft], or `null` when cancelled.
class DapConnectionEditorPage extends StatefulWidget {
  const DapConnectionEditorPage({
    super.key,
    required this.initialUrl,
    this.initialName,
  });

  /// The resolved URL (the zero-config default on first run).
  final String initialUrl;

  /// The saved agent name, when set — `null` renders the add variant.
  final String? initialName;

  @override
  State<DapConnectionEditorPage> createState() =>
      _DapConnectionEditorPageState();
}

class _DapConnectionEditorPageState extends State<DapConnectionEditorPage> {
  late final _urlController = TextEditingController(text: widget.initialUrl);
  late final _nameController = TextEditingController(
    text: widget.initialName ?? '',
  );
  String? _error;

  bool get _isAdd => widget.initialName == null;

  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.screenOpened('settings_dap_editor');
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _save() {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = context.l10n.settingsDapUrlRequired);
      return;
    }
    Navigator.of(
      context,
    ).pop(DapConnectionDraft(url: url, name: _nameController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: faAppBar(
        title: Text(
          _isAdd
              ? context.l10n.settingsDapAddConnection
              : context.l10n.settingsDapEditConnection,
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: context.l10n.settingsDapUrlLabel,
                  hintText: context.l10n.settingsDapUrlHint,
                  helperText: context.l10n.settingsDapUrlHint,
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: context.l10n.settingsDapAgentNameLabel,
                  hintText: context.l10n.settingsDapNameHint,
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(context.l10n.settingsCancelButton),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _save,
                    child: Text(context.l10n.settingsSaveButton),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
