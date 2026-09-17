// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_network_controller.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/dap_binding_store.dart';
import 'package:fa/services/dap_service.dart';
import 'package:fa/services/dap_service_web_core.dart'
    show ExtensionDapHubService, normalizeWebDapHost;
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/dap_hub_mark.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show AgentPresence, HubLinkState, MailboxEntry;

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
            const DapHubMark(size: 20),
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
  const DapHubPage({super.key, this.service, this.agentNetwork});

  /// Overrides the platform service (tests); defaults to the real one.
  final DapHubService? service;

  /// Overrides the app agent's membership controller (tests, goldens);
  /// defaults to the live service instance.
  final AgentNetworkController? agentNetwork;

  @override
  State<DapHubPage> createState() => _DapHubPageState();
}

class _DapHubPageState extends State<DapHubPage> {
  late final DapHubService _service = widget.service ?? createDapHubService();
  DapHubSnapshot? _snapshot;
  String? _error;
  var _probing = false;

  /// Named-mode picker options + in-flight binding save.
  List<DapBindableSession>? _bindableSessions;
  var _savingBinding = false;

  /// Bookmarked hub connections (extension only — null hides the section).
  List<DapSavedConnection>? _saved;
  var _switchingConnection = false;

  /// The connection whose detail view is open (null = the list view).
  /// The list and the details are the SAME page — tapping a row flips it
  /// to that connection's details (url, identity, incoming routing),
  /// back returns to the list.
  DapSavedConnection? _selected;

  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.screenOpened('settings_dap_hub');
    _reload();
  }

  Future<void> _reload() async {
    try {
      final loaded = await _loadSnapshot();
      if (mounted) {
        setState(() {
          _snapshot = loaded.snapshot;
          _bindableSessions = loaded.sessions;
          _saved = loaded.saved;
          _error = null;
        });
      }
    } on Object {
      // Corrupt/unreadable ~/.dap layout: an error state, never a spinner.
      if (!mounted) return;
      setState(() => _error = context.l10n.settingsDapLoadFailed);
    }
  }

  /// One load pass: the snapshot, the named-mode picker options (supported
  /// hosts only), and the bookmark list (extension only, best effort).
  Future<
    ({
      DapHubSnapshot snapshot,
      List<DapBindableSession> sessions,
      List<DapSavedConnection>? saved,
    })
  >
  _loadSnapshot() async {
    final snapshot = await _service.load();
    final sessions = snapshot.supported
        ? await _service.listBindableSessions()
        : const <DapBindableSession>[];
    return (
      snapshot: snapshot,
      sessions: sessions,
      saved: await _savedConnections(),
    );
  }

  /// The bookmarked connections, or null where the host has none (the list
  /// section stays hidden). A failed read hides the section — never errors.
  Future<List<DapSavedConnection>?> _savedConnections() async {
    final extService = _service;
    if (extService is! ExtensionDapHubService) return null;
    try {
      return await extService.savedConnections();
    } on Object {
      return null;
    }
  }

  Future<void> _probe() async {
    if (_probing) return;
    setState(() => _probing = true);
    AppAnalytics.instance.dapHubAction('probe');
    final snapshot = await _probeSnapshot();
    if (!mounted) return;
    setState(() {
      if (snapshot != null) _snapshot = snapshot;
      _probing = false;
    });
  }

  /// One probe pass: the fresh snapshot, or null when the probe failed
  /// (the spinner just stops — the stale snapshot stays on screen).
  Future<DapHubSnapshot?> _probeSnapshot() async {
    try {
      return await _service.probe();
    } on Object {
      return null;
    }
  }

  Future<void> _edit() async {
    final snapshot = _snapshot;
    if (snapshot == null || !snapshot.supported) return;
    AppAnalytics.instance.dapHubAction('edit');
    final draft = await _pushEditor(
      DapConnectionEditorPage(
        initialUrl: snapshot.url,
        initialName: snapshot.name,
      ),
    );
    if (draft == null || !await _commitDraft(draft)) return;
    AppAnalytics.instance.dapHubAction('save');
    await _upsertFromDraft(draft);
    await _reload();
  }

  /// Inserts or updates [entry] in the bookmark list. An empty [secret]
  /// keeps the bookmarked secret of the same-url entry (the stored hub
  /// password is never echoed back into the UI).
  Future<void> _upsertSaved(DapSavedConnection entry) async {
    final service = _service;
    if (service is! ExtensionDapHubService) return;
    final updated = mergeDapSavedConnections(
      await service.savedConnections(),
      entry,
    );
    try {
      await service.setSavedConnections(updated);
    } on Object {
      // The bookmark write is best effort — the connection itself saved.
    }
  }

  /// "Add connection": saves the draft as a bookmark AND makes it the
  /// active connection (the SW reboots the live agent onto it).
  Future<void> _addConnection() async {
    final draft = await _pushEditor(
      const DapConnectionEditorPage(initialUrl: ''),
    );
    if (draft == null || !await _commitDraft(draft)) return;
    AppAnalytics.instance.dapHubAction('add');
    await _upsertFromDraft(draft);
    await _reload();
  }

  /// Pushes the add/edit form; the popped draft, or null when cancelled.
  Future<DapConnectionDraft?> _pushEditor(DapConnectionEditorPage page) =>
      faui.pushFaPage<DapConnectionDraft>(context, page);

  /// Persists the draft to the shared config. False = the save failed and
  /// the user was told (the flow stops — no bookmark, no analytics save).
  Future<bool> _commitDraft(DapConnectionDraft draft) async {
    try {
      await _service.saveConnection(
        url: draft.url,
        name: draft.name,
        secret: (draft.secret ?? '').trim().isEmpty ? null : draft.secret,
      );
    } on Object {
      // Bad host (normalizeDapHost) or a failed config write: tell the
      // user instead of an unhandled async exception.
      if (!mounted) return false;
      _showSaveFailed();
      return false;
    }
    return true;
  }

  /// Keeps the bookmark list in lockstep with the active connection: the
  /// entry (matched by url) is upserted with the typed secret, or keeps
  /// its stored one when the write-only field was left empty.
  Future<void> _upsertFromDraft(DapConnectionDraft draft) => _upsertSaved(
    DapSavedConnection(
      url: normalizeWebDapHost(draft.url.trim()),
      name: draft.name.trim(),
      secret: (draft.secret ?? '').trim(),
    ),
  );

  /// Tapping a non-active bookmark switches the live agent onto it.
  Future<void> _switchTo(DapSavedConnection entry) async {
    if (_switchingConnection) return;
    setState(() => _switchingConnection = true);
    AppAnalytics.instance.dapHubAction('switch');
    try {
      await (_service as ExtensionDapHubService).switchConnection(entry.url);
    } on Object {
      if (!mounted) return;
      _showSaveFailed();
    } finally {
      if (mounted) setState(() => _switchingConnection = false);
    }
    await _reload();
  }

  /// Drops a bookmark. The active connection may stay active without its
  /// bookmark — only the list entry is removed.
  Future<void> _removeSaved(DapSavedConnection entry) async {
    final service = _service;
    if (service is! ExtensionDapHubService) return;
    final updated = <DapSavedConnection>[...?_saved]
      ..removeWhere((e) => e.url == entry.url);
    try {
      await service.setSavedConnections(updated);
    } on Object {
      if (!mounted) return;
      _showSaveFailed();
      return;
    }
    await _reload();
  }

  Future<void> _saveBinding(
    DapInboundMode mode, {
    String? sessionId,
    String? sessionTitle,
  }) async {
    if (_savingBinding) return;
    setState(() => _savingBinding = true);
    AppAnalytics.instance.dapHubAction('bind_${mode.name}');
    try {
      await _service.saveBinding(
        mode,
        sessionId: sessionId,
        sessionTitle: sessionTitle,
      );
    } on Object {
      if (!mounted) return;
      _showSaveFailed();
    } finally {
      if (mounted) setState(() => _savingBinding = false);
    }
    unawaited(DapBindingStore.instance.refresh());
    await _reload();
  }

  /// The shared save-failure note (connection, bookmark, binding, switch).
  void _showSaveFailed() {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(context.l10n.settingsDapSaveFailed)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final selected = _selected;
    final detailTitle = selected == null
        ? context.l10n.settingsDapHubTitle
        : (selected.name.isEmpty ? selected.url : selected.name);
    return Scaffold(
      appBar: faAppBar(
        title: Text(detailTitle),
        leading: selected == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selected = null),
              ),
      ),
      body: snapshot == null
          ? _error != null
                ? _messageBody(context, _error!)
                : const Center(child: CircularProgressIndicator())
          : snapshot.supported
          ? selected == null
                ? _listBody(context, snapshot)
                : _detailBody(context, snapshot, selected)
          : _unsupportedBody(context),
    );
  }

  /// The connections list: the active connection first (always present —
  /// synthesized from the snapshot when never bookmarked), then the
  /// bookmarks. Tapping a row opens its details; Add appends a new hub.
  Widget _listBody(BuildContext context, DapHubSnapshot snapshot) {
    final theme = Theme.of(context);
    final colors = FahColors.of(context);
    final rows = _rowsFor(snapshot);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.settingsDapHubIntro,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
            ),
            const SizedBox(height: 16),
            AgentNetworkSection(controller: widget.agentNetwork),
            const SizedBox(height: 16),
            Text(
              context.l10n.settingsDapSavedTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.settingsDapSavedHint,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
            ),
            const SizedBox(height: 8),
            for (final row in rows)
              _connectionRow(context, snapshot, row.connection, row.active),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addConnection,
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.l10n.settingsDapAddConnection),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The detail view: the active connection gets the full body (url,
  /// status, identity, incoming routing, channels, edit); a bookmark gets
  /// its coordinates plus Make active / Remove.
  Widget _detailBody(
    BuildContext context,
    DapHubSnapshot snapshot,
    DapSavedConnection selected,
  ) {
    if (selected.url == snapshot.url) return _connectionBody(context, snapshot);
    return _bookmarkDetailBody(context, snapshot, selected);
  }

  /// Rows for the list: the active connection first (synthesized when it
  /// has no bookmark yet), then the bookmarked ones.
  List<({DapSavedConnection connection, bool active})> _rowsFor(
    DapHubSnapshot snapshot,
  ) {
    final saved = _saved ?? const <DapSavedConnection>[];
    final rows = <({DapSavedConnection connection, bool active})>[];
    var activeListed = false;
    for (final entry in saved) {
      final active = entry.url == snapshot.url;
      activeListed |= active;
      rows.add((connection: entry, active: active));
    }
    if (!activeListed) {
      rows.insert(0, (
        connection: DapSavedConnection(
          url: snapshot.url,
          name: snapshot.name ?? '',
        ),
        active: true,
      ));
    }
    return rows;
  }

  /// One connection row: the active marker (teal dot + Active chip), name
  /// and url. Tapping opens the detail view — switching lives there.
  Widget _connectionRow(
    BuildContext context,
    DapHubSnapshot snapshot,
    DapSavedConnection entry,
    bool active,
  ) {
    final theme = Theme.of(context);
    final colors = FahColors.of(context);
    final selected = _selected?.url == entry.url;
    return ListTile(
      key: ValueKey('dapConn-${entry.url}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: _activeDot(colors, active),
      title: Row(
        children: [
          Expanded(child: _connectionTitle(context, entry, active)),
          if (active) _activeChip(context),
        ],
      ),
      subtitle: Text(
        entry.url,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.dim,
          fontFamily: 'JetBrainsMono',
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: selected ? colors.teal : colors.dim,
      ),
      onTap: () => setState(() => _selected = entry),
    );
  }

  /// The row's display name: the saved name, or the url when unnamed;
  /// bolder when this is the active connection.
  Widget _connectionTitle(
    BuildContext context,
    DapSavedConnection entry,
    bool active,
  ) {
    final theme = Theme.of(context);
    return Text(
      entry.name.isEmpty ? entry.url : entry.name,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: active ? FontWeight.w600 : null,
      ),
    );
  }

  /// The 10px status dot in front of a row.
  Widget _activeDot(FahColors colors, bool active) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: active ? colors.teal : colors.dim.withValues(alpha: 0.4),
    ),
  );

  /// The teal Active chip on the active row.
  Widget _activeChip(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      context.l10n.settingsDapActiveChip,
      style: theme.textTheme.labelSmall?.copyWith(
        color: FahColors.of(context).teal,
      ),
    );
  }

  /// A non-active bookmark's details: its coordinates, the shared agent
  /// identity, and the live switch.
  Widget _bookmarkDetailBody(
    BuildContext context,
    DapHubSnapshot snapshot,
    DapSavedConnection entry,
  ) {
    final theme = Theme.of(context);
    final colors = FahColors.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _labeledRow(
              context,
              context.l10n.settingsDapUrlLabel,
              entry.url,
              mono: true,
            ),
            _labeledRow(
              context,
              context.l10n.settingsDapAgentNameLabel,
              entry.name.isEmpty ? '—' : entry.name,
            ),
            _labeledRow(
              context,
              context.l10n.settingsDapAgentIdLabel,
              snapshot.agentId ?? '—',
              mono: true,
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.settingsDapIdentityHint,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
            ),
            const SizedBox(height: 24),
            _makeActiveButton(context, entry),
            const SizedBox(height: 8),
            _removeSavedButton(context, entry),
          ],
        ),
      ),
    );
  }

  /// The live switch: swaps the spinner in while a switch is in flight.
  Widget _makeActiveButton(BuildContext context, DapSavedConnection entry) {
    return FilledButton.icon(
      onPressed: _switchingConnection
          ? null
          : () async {
              await _switchTo(entry);
              if (mounted) setState(() => _selected = entry);
            },
      icon: _switchingConnection
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.swap_horiz, size: 18),
      label: Text(context.l10n.settingsDapMakeActive),
    );
  }

  /// Drops the bookmark from the detail view.
  Widget _removeSavedButton(BuildContext context, DapSavedConnection entry) {
    final theme = Theme.of(context);
    return OutlinedButton.icon(
      onPressed: _switchingConnection
          ? null
          : () async {
              await _removeSaved(entry);
              if (mounted) setState(() => _selected = null);
            },
      icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
      label: Text(context.l10n.settingsDapRemoveSaved),
      style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
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
            Text(
              context.l10n.settingsDapIdentityTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.settingsDapIdentityHint,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
            ),
            const SizedBox(height: 12),
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
            ..._inboundSection(context, snapshot),
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

  /// The inbound-mail routing section: where messages from other agents
  /// land. Three modes (dedicated session / open session / picked
  /// session); the named mode unfolds a session picker.
  List<Widget> _inboundSection(BuildContext context, DapHubSnapshot snapshot) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final sessions = _bindableSessions ?? const <DapBindableSession>[];
    return [
      Text(l10n.settingsDapInboundTitle, style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(
        l10n.settingsDapInboundHint,
        style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
      ),
      const SizedBox(height: 8),
      // Display order: dedicated, open session, picked session.
      for (final mode in const [
        DapInboundMode.dedicated,
        DapInboundMode.currentSession,
        DapInboundMode.named,
      ])
        _inboundModeRow(context, snapshot, mode, sessions),
      if (snapshot.inboundMode == DapInboundMode.named &&
          sessions.isNotEmpty) ...[
        const SizedBox(height: 4),
        _inboundPicker(context, snapshot, sessions),
      ],
    ];
  }

  /// One mode row: the label, the bound-session detail line while
  /// selected, and the tap that persists the mode.
  Widget _inboundModeRow(
    BuildContext context,
    DapHubSnapshot snapshot,
    DapInboundMode mode,
    List<DapBindableSession> sessions,
  ) {
    final l10n = context.l10n;
    final selected = snapshot.inboundMode == mode;
    return _inboundOption(
      context,
      selected: selected,
      label: switch (mode) {
        DapInboundMode.dedicated => l10n.settingsDapInboundDedicated,
        DapInboundMode.currentSession => l10n.settingsDapInboundCurrent,
        DapInboundMode.named => l10n.settingsDapInboundNamed,
      },
      detail: selected && mode != DapInboundMode.currentSession
          ? snapshot.boundSessionTitle
          : null,
      onTap: _inboundOnTap(mode, sessions),
    );
  }

  /// What tapping a mode row does: named needs a session (the row is dead
  /// while none is enumerable); the other two just persist their mode.
  VoidCallback? _inboundOnTap(
    DapInboundMode mode,
    List<DapBindableSession> sessions,
  ) => switch (mode) {
    DapInboundMode.named when sessions.isEmpty => null,
    DapInboundMode.named => () => _saveBinding(
      DapInboundMode.named,
      sessionId: sessions.first.id,
      sessionTitle: sessions.first.title,
    ),
    _ => () => _saveBinding(mode),
  };

  /// The named-mode session picker: preselected to the bound session.
  Widget _inboundPicker(
    BuildContext context,
    DapHubSnapshot snapshot,
    List<DapBindableSession> sessions,
  ) {
    return DropdownMenu<String>(
      initialSelection: sessions
          .where((entry) => entry.title == snapshot.boundSessionTitle)
          .firstOrNull
          ?.id,
      enabled: !_savingBinding,
      dropdownMenuEntries: [
        for (final entry in sessions)
          DropdownMenuEntry<String>(value: entry.id, label: entry.title),
      ],
      onSelected: (id) {
        final entry = sessions.where((e) => e.id == id).firstOrNull;
        if (entry == null) return;
        _saveBinding(
          DapInboundMode.named,
          sessionId: entry.id,
          sessionTitle: entry.title,
        );
      },
    );
  }

  /// One selectable inbound-routing row (radio-style, no deprecated
  /// RadioListTile groupValue plumbing).
  Widget _inboundOption(
    BuildContext context, {
    required bool selected,
    required String label,
    String? detail,
    VoidCallback? onTap,
  }) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _savingBinding ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected ? theme.colorScheme.primary : colors.dim,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.bodyMedium),
                  if (detail != null)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.dim,
                      ),
                    ),
                ],
              ),
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
  Widget _unsupportedBody(BuildContext context) =>
      _messageBody(context, context.l10n.settingsDapUnsupported);

  /// A centered icon + message: the not-supported note and the load-error
  /// state share this layout.
  Widget _messageBody(BuildContext context, String message) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DapHubMark(size: 40),
              const SizedBox(height: 12),
              Text(
                message,
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

/// The bookmark list after upserting [entry] (one entry per url). An empty
/// [entry.secret] keeps the stored secret of the same-url entry (the stored
/// hub password is never echoed back into the UI); same-url entries fold
/// into the one appended at the end. Pure — unit tested.
List<DapSavedConnection> mergeDapSavedConnections(
  List<DapSavedConnection> current,
  DapSavedConnection entry,
) {
  final keepSecret = current
      .where((e) => e.url == entry.url && e.secret.isNotEmpty)
      .map((e) => e.secret)
      .firstOrNull;
  return [
    for (final e in current)
      if (e.url != entry.url) e,
    DapSavedConnection(
      url: entry.url,
      name: entry.name,
      secret: entry.secret.isNotEmpty ? entry.secret : keepSecret ?? '',
    ),
  ];
}

/// The values collected by the [DapConnectionEditorPage].
final class DapConnectionDraft {
  const DapConnectionDraft({
    required this.url,
    required this.name,
    this.secret,
  });

  final String url;
  final String name;

  /// The hub password as typed — `null`/empty keeps the stored one (the
  /// field is write-only: a saved password is never echoed back).
  final String? secret;
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
  late final _secretController = TextEditingController();
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
    _secretController.dispose();
    super.dispose();
  }

  void _save() {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = context.l10n.settingsDapUrlRequired);
      return;
    }
    Navigator.of(context).pop(
      DapConnectionDraft(
        url: url,
        name: _nameController.text.trim(),
        secret: _secretController.text.trim(),
      ),
    );
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
              const SizedBox(height: 12),
              TextField(
                controller: _secretController,
                decoration: InputDecoration(
                  labelText: context.l10n.settingsDapPasswordLabel,
                  helperText: context.l10n.settingsDapPasswordHint,
                ),
                obscureText: true,
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

/// The agent membership section (issue #402 AC5): the opt-in toggle, the
/// live link state with this agent's hub address, the roster (peers), and
/// a DM composer. Reads the live [AgentNetworkController] off the app's
/// service; [controller] overrides it (tests, goldens).
class AgentNetworkSection extends StatefulWidget {
  const AgentNetworkSection({super.key, this.controller});

  /// Overrides the live controller (tests); defaults to the app service's.
  final AgentNetworkController? controller;

  @override
  State<AgentNetworkSection> createState() => _AgentNetworkSectionState();
}

class _AgentNetworkSectionState extends State<AgentNetworkSection> {
  AgentNetworkController? _controller;
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _name = TextEditingController();
  final _dm = TextEditingController();
  final _dmFocus = FocusNode();
  List<MailboxEntry>? _peers;
  String? _dmTarget;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _bind(widget.controller ?? AgentService.maybeCurrent?.agentNetwork);
  }

  @override
  void didUpdateWidget(covariant AgentNetworkSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _bind(widget.controller ?? AgentService.maybeCurrent?.agentNetwork);
    }
  }

  void _bind(AgentNetworkController? controller) {
    _controller?.removeListener(_refreshPeers);
    _controller = controller;
    controller?.addListener(_refreshPeers);
    final store = controller?.store;
    _url.text = store?.url ?? '';
    _token.text = store?.token ?? '';
    _name.text = store?.name ?? '';
    _refreshPeers();
  }

  @override
  void dispose() {
    _controller?.removeListener(_refreshPeers);
    _url.dispose();
    _token.dispose();
    _name.dispose();
    _dm.dispose();
    _dmFocus.dispose();
    super.dispose();
  }

  Future<void> _refreshPeers() async {
    final controller = _controller;
    final peers = controller == null
        ? const <MailboxEntry>[]
        : await controller.peers();
    if (mounted) setState(() => _peers = peers);
  }

  Future<void> _toggle(bool value) async {
    final controller = _controller;
    if (controller == null) return;
    AppAnalytics.instance.dapHubAction('agent-network-toggle');
    await controller.setEnabled(value);
    await _refreshPeers();
  }

  Future<void> _save() async {
    final controller = _controller;
    if (controller == null || _saving) return;
    setState(() => _saving = true);
    await controller.saveConnection(
      url: _url.text,
      token: _token.text,
      name: _name.text,
    );
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.settingsAgentNetworkSaved)),
      );
    }
    setState(() => _saving = false);
    await _refreshPeers();
  }

  Future<void> _sendDm() async {
    final controller = _controller;
    final target = _dmTarget;
    final text = _dm.text.trim();
    if (controller == null || target == null || text.isEmpty) return;
    await controller.sendDm(target, text);
    _dm.clear();
    if (mounted) setState(() => _dmTarget = null);
    unawaited(_refreshPeers());
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    if (controller == null || !controller.supported) {
      return Row(
        children: [
          const DapHubMark(size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.settingsAgentNetworkUnsupported,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
            ),
          ),
        ],
      );
    }
    final store = controller.store;
    final enabled = store.enabled;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: colors.dim.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.settingsAgentNetworkJoin,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.settingsAgentNetworkJoinHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.dim,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(value: enabled, onChanged: _toggle),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 12),
            _statusRow(context, controller),
            const SizedBox(height: 12),
            _connectionFields(context),
            const SizedBox(height: 12),
            _peersList(context, controller),
          ],
        ],
      ),
    );
  }

  /// The live link state: chip + this agent's hub address.
  Widget _statusRow(BuildContext context, AgentNetworkController controller) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    final (label, color) = switch (controller.state) {
      HubLinkState.connected => (
        context.l10n.settingsAgentNetworkConnected,
        Colors.green,
      ),
      HubLinkState.connecting => (
        context.l10n.settingsAgentNetworkConnecting,
        Colors.orange,
      ),
      _ => (context.l10n.settingsAgentNetworkOffline, colors.dim),
    };
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(label, style: theme.textTheme.bodyMedium),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            controller.agentId ?? '',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.dim,
              fontFamily: 'JetBrainsMono',
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _connectionFields(BuildContext context) {
    final theme = Theme.of(context);
    InputDecoration decoration(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    );
    return Column(
      children: [
        TextField(
          controller: _url,
          decoration: decoration(context.l10n.settingsAgentNetworkUrl),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _name,
                decoration: decoration(context.l10n.settingsAgentNetworkName),
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _token,
                obscureText: true,
                decoration: decoration(context.l10n.settingsAgentNetworkToken),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(context.l10n.settingsAgentNetworkSave),
          ),
        ),
      ],
    );
  }

  Widget _peersList(BuildContext context, AgentNetworkController controller) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    final peers = _peers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.settingsAgentNetworkPeers,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        if (peers == null || peers.isEmpty)
          Text(
            context.l10n.settingsAgentNetworkNoPeers,
            style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
          )
        else
          for (final peer in peers) _peerRow(context, peer),
        if (_dmTarget != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _dm,
                  focusNode: _dmFocus,
                  decoration: InputDecoration(
                    labelText: context.l10n.settingsAgentNetworkDmHint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  style: theme.textTheme.bodySmall,
                  onSubmitted: (_) => _sendDm(),
                ),
              ),
              IconButton(
                tooltip: context.l10n.settingsAgentNetworkSend,
                icon: const Icon(Icons.send_outlined, size: 18),
                onPressed: _sendDm,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _peerRow(BuildContext context, MailboxEntry peer) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    final selected = _dmTarget == peer.id;
    return InkWell(
      onTap: () => setState(() => _dmTarget = selected ? null : peer.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              selected ? Icons.chat_bubble_outline : Icons.computer,
              size: 16,
              color: selected ? theme.colorScheme.primary : colors.dim,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                peer.name ?? peer.id,
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(switch (peer.presence) {
              AgentPresence.live => context.l10n.settingsAgentNetworkConnected,
              AgentPresence.busy => context.l10n.settingsAgentNetworkConnecting,
              _ => context.l10n.settingsAgentNetworkOffline,
            }, style: theme.textTheme.labelSmall?.copyWith(color: colors.dim)),
          ],
        ),
      ),
    );
  }
}
