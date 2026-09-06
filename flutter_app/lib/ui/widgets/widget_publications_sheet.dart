// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';

/// Opens the "My publications" sheet (issue #35, card AC7): every recorded
/// submission with its PR state chip, plus a Refresh action that re-reads
/// the live PR states through [service] (when provided — otherwise the
/// sheet is a read-only view of each submission's last-known state).
Future<void> showWidgetPublicationsSheet(
  BuildContext context, {
  required WidgetPublicationStore ledger,
  WidgetPublishService? service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => WidgetPublicationsSheet(ledger: ledger, service: service),
  );
}

/// The publications sheet body (also embeddable in tests).
class WidgetPublicationsSheet extends StatefulWidget {
  const WidgetPublicationsSheet({
    super.key,
    required this.ledger,
    this.service,
  });

  final WidgetPublicationStore ledger;

  /// Status refresher; null renders the read-only last-known projection.
  final WidgetPublishService? service;

  @override
  State<WidgetPublicationsSheet> createState() =>
      _WidgetPublicationsSheetState();
}

class _WidgetPublicationsSheetState extends State<WidgetPublicationsSheet> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    final service = widget.service;
    if (service == null || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      // refreshStatus persists the new state into the ledger (and notifies
      // listeners) itself; a single failure (offline, deleted repo) must
      // not block the rest.
      for (final publication in widget.ledger.publications) {
        try {
          await service.refreshStatus(publication);
        } on Object {
          continue;
        }
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.myPublications,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (widget.service != null)
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
          const SizedBox(height: 8),
          Flexible(
            child: ListenableBuilder(
              listenable: widget.ledger,
              builder: (context, _) {
                final publications = widget.ledger.publications;
                if (publications.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        l10n.publicationsEmpty,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: publications.length,
                  itemBuilder: (context, index) =>
                      _PublicationTile(publication: publications[index]),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _PublicationTile extends StatelessWidget {
  const _PublicationTile({required this.publication});

  final WidgetPublication publication;

  String _submittedDate() {
    final local = publication.submittedAt.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(publication.widgetId, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                InkWell(
                  onTap: () => unawaited(
                    url_launcher.launchUrl(
                      Uri.parse(publication.prUrl),
                      mode: url_launcher.LaunchMode.externalApplication,
                    ),
                  ),
                  child: Text(
                    '${publication.repoFullName} · PR #${publication.prNumber}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.publicationSubmittedAt(_submittedDate()),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _StateChip(state: publication.state),
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final WidgetPublicationState state;

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
      WidgetPublicationState.unknown => (
        l10n.publicationStateUnknown,
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
