// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa/ui/widgets/github_account_section.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Opens the per-widget detail sheet (issue #1045, owner ruling verbatim:
/// «пусть в get widgets при клике на item появится деталька и там пусть
/// будет инфомация и статус»): widget info + LIVE publish status —
/// not-published / publishing / validating / PR open / published /
/// rejected / INVALID with the validator's verbatim error lines + the CI
/// run link — readable without leaving the app.
///
/// [env] resolves the shared publication ledger; when a GitHub account is
/// reachable the sheet also live-refreshes (one refresh on open, a manual
/// refresh button, and a [pollInterval] timer while open). Without an
/// account it renders the last-known states read-only.
Future<void> showWidgetStatusDetailSheet(
  BuildContext context, {
  required String widgetId,
  required String title,
  String? version,
  String? description,
  String? author,
  required ExecutionEnv env,
  Duration pollInterval = WidgetStatusDetailSheet.defaultPollInterval,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => WidgetStatusDetailSheet(
      widgetId: widgetId,
      title: title,
      version: version,
      description: description,
      author: author,
      env: env,
      pollInterval: pollInterval,
    ),
  );
}

/// The detail sheet body (also embeddable in tests).
class WidgetStatusDetailSheet extends StatefulWidget {
  const WidgetStatusDetailSheet({
    super.key,
    required this.widgetId,
    required this.title,
    this.version,
    this.description,
    this.author,
    required this.env,
    this.pollInterval = defaultPollInterval,
  });

  /// Cadence of the live status polling while the sheet is open — a
  /// publish the user just fire-and-forgot (AC6) resolves here within a
  /// tick or two, without any manual refresh.
  static const defaultPollInterval = Duration(seconds: 30);

  final String widgetId;
  final String title;
  final String? version;
  final String? description;
  final String? author;
  final ExecutionEnv env;
  final Duration pollInterval;

  @override
  State<WidgetStatusDetailSheet> createState() =>
      _WidgetStatusDetailSheetState();
}

class _WidgetStatusDetailSheetState extends State<WidgetStatusDetailSheet> {
  WidgetPublishService? _service;
  bool _refreshing = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _resolveService();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Builds the publish service from the shared account + ledger (the same
  /// ad-hoc wiring the launcher's publish menu uses); a missing keys store
  /// keeps the sheet read-only.
  Future<void> _resolveService() async {
    try {
      final keys =
          SessionKeysScope.maybeOf(context) ??
          await SessionKeysStore.load(widget.env);
      final ledger = await initSharedWidgetPublicationStore(widget.env);
      if (!mounted) return;
      setState(() {
        _service = WidgetPublishService(
          env: widget.env,
          account: sharedGithubAccountStore(keys),
          ledger: ledger,
        );
      });
      await _refresh();
      _startTimer();
    } on Object {
      // Read-only degrade: last-known states still render (I3).
    }
  }

  void _startTimer() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(widget.pollInterval, (_) => _refresh());
  }

  Future<void> _refresh() async {
    final service = _service;
    if (service == null || _refreshing || !mounted) return;
    final publication = sharedWidgetPublicationStore().byWidgetId(
      widget.widgetId,
    );
    if (publication == null || publication.prNumber == null) return;
    setState(() => _refreshing = true);
    try {
      await service.refreshStatus(publication);
    } on Object {
      // Offline / rate limit — the chip keeps its last-known state.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.title, style: theme.textTheme.titleMedium),
              ),
              IconButton(
                tooltip: l10n.publicationsRefresh,
                onPressed: _refreshing ? null : _refresh,
                icon: _refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (widget.version != null)
            _infoRow(theme, l10n.widgetDetailVersion, widget.version!),
          if (widget.author != null && widget.author!.isNotEmpty)
            _infoRow(theme, l10n.widgetDetailAuthor, widget.author!),
          if (widget.description != null && widget.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              widget.description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const Divider(height: 24),
          // Status rides the ledger — every record (optimistic publishing,
          // CI verdicts, failures) notifies listeners.
          ListenableBuilder(
            listenable: sharedWidgetPublicationStore(),
            builder: (context, _) {
              final publication = sharedWidgetPublicationStore().byWidgetId(
                widget.widgetId,
              );
              return _StatusSection(publication: publication);
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _infoRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// The live publish-status block: chip, links, verbatim errors.
class _StatusSection extends StatelessWidget {
  const _StatusSection({this.publication});

  final WidgetPublication? publication;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final publication = this.publication;
    if (publication == null) {
      return _StatusChip(state: WidgetPublicationState.unknown, missing: true);
    }
    final state = publication.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _StatusChip(state: state),
            if (publication.prNumber != null)
              InkWell(
                onTap: () => unawaited(
                  url_launcher.launchUrl(
                    Uri.parse(publication.prUrl),
                    mode: url_launcher.LaunchMode.externalApplication,
                  ),
                ),
                child: Text(
                  '#${publication.prNumber}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
          ],
        ),
        if (state == WidgetPublicationState.invalid &&
            publication.validatorErrors.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            l10n.widgetStatusErrors,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 6),
          // VERBATIM validator output (issue #1045): selectable plain text,
          // never reworded or aggregated — what CI said is what renders.
          SelectableText(
            publication.validatorErrors.join('\n'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              fontFamily: 'JetBrainsMono',
              height: 1.4,
            ),
          ),
        ],
        if (state == WidgetPublicationState.failed &&
            publication.lastError != null) ...[
          const SizedBox(height: 12),
          SelectableText(
            publication.lastError!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (publication.runHtmlUrl != null) ...[
          const SizedBox(height: 8),
          InkWell(
            onTap: () => unawaited(
              url_launcher.launchUrl(
                Uri.parse(publication.runHtmlUrl!),
                mode: url_launcher.LaunchMode.externalApplication,
              ),
            ),
            child: Text(
              l10n.widgetStatusOpenRun,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The status chip: one label per lifecycle state (issue #1045 states
/// included), reusing the publications-sheet palette.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state, this.missing = false});

  final WidgetPublicationState state;

  /// True when the widget has no ledger record at all — rendered from
  /// [WidgetPublicationState.unknown] but labelled "Not published".
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (label, color) = switch (state) {
      WidgetPublicationState.open => (l10n.publicationStateOpen, Colors.blue),
      WidgetPublicationState.published => (
        l10n.publicationStatePublished,
        Colors.green,
      ),
      WidgetPublicationState.rejected => (
        l10n.publicationStateRejected,
        Colors.red,
      ),
      WidgetPublicationState.publishing => (
        l10n.publishInProgress,
        Colors.blue,
      ),
      WidgetPublicationState.validating => (
        l10n.widgetStatusValidating,
        Colors.orange,
      ),
      WidgetPublicationState.invalid => (l10n.widgetStatusInvalid, Colors.red),
      WidgetPublicationState.failed => (l10n.widgetStatusFailed, Colors.red),
      WidgetPublicationState.unknown => (
        missing ? l10n.widgetStatusNotPublished : l10n.publicationStateUnknown,
        Colors.grey,
      ),
    };
    return Chip(
      label: Text(label),
      labelStyle: TextStyle(color: color),
      side: BorderSide(color: color),
      backgroundColor: color.withValues(alpha: 0.08),
      visualDensity: VisualDensity.compact,
    );
  }
}
