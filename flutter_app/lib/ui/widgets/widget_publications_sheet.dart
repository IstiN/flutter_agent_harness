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
///
/// With a [service], the sheet also runs the card's timed status polling:
/// a refresh every [pollInterval] while the sheet is open and one refresh
/// when the app resumes to the foreground — no network while the sheet is
/// closed (boot never blocks on GitHub).
Future<void> showWidgetPublicationsSheet(
  BuildContext context, {
  required WidgetPublicationStore ledger,
  WidgetPublishService? service,
  Duration pollInterval = WidgetPublicationsSheet.defaultPollInterval,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => WidgetPublicationsSheet(
      ledger: ledger,
      service: service,
      pollInterval: pollInterval,
    ),
  );
}

/// The publications sheet body (also embeddable in tests).
class WidgetPublicationsSheet extends StatefulWidget {
  const WidgetPublicationsSheet({
    super.key,
    required this.ledger,
    this.service,
    this.pollInterval = defaultPollInterval,
  });

  /// Cadence of the timed status polling while the sheet is open — the
  /// card's 5-minute background cadence. Injectable for the same reason
  /// as the connect sheet's `httpClient`: tests fire the poll with short
  /// pumps instead of waiting five minutes.
  static const defaultPollInterval = Duration(minutes: 5);

  final WidgetPublicationStore ledger;

  /// Status refresher; null renders the read-only last-known projection.
  final WidgetPublishService? service;

  final Duration pollInterval;

  @override
  State<WidgetPublicationsSheet> createState() =>
      _WidgetPublicationsSheetState();
}

class _WidgetPublicationsSheetState extends State<WidgetPublicationsSheet>
    with WidgetsBindingObserver {
  bool _refreshing = false;

  /// True when the latest refresh cycle could not reach a single PR —
  /// the sheet then says it is showing last-known states (AC8 offline
  /// degrade) instead of silently stale chips.
  bool _offline = false;

  Timer? _pollTimer;

  /// Consecutive fully-failed refresh cycles — stretches the next poll
  /// delay (E2: an offline / rate-limited account must not be hammered
  /// every interval).
  int _failedCycles = 0;

  @override
  void initState() {
    super.initState();
    if (widget.service != null) {
      WidgetsBinding.instance.addObserver(this);
      _startTimer();
    }
  }

  /// Schedules the next poll tick. Self-rescheduling (not periodic) so a
  /// run of failed cycles can stretch the cadence: 1x → 2x → 4x → 8x of
  /// [WidgetPublicationsSheet.pollInterval], capped; the first reaching
  /// cycle resets to 1x.
  void _startTimer() {
    _pollTimer?.cancel();
    final stretch = 1 << _failedCycles.clamp(0, 3);
    _pollTimer = Timer(widget.pollInterval * stretch, _onTick);
  }

  Future<void> _onTick() async {
    await _refresh();
    if (!mounted) return;
    _failedCycles = _offline ? _failedCycles + 1 : 0;
    _startTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // Background pause (E2): while backgrounded the timer is
        // cancelled, so resuming refreshes once and restarts the cadence.
        _refresh();
        _startTimer();
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _pollTimer?.cancel();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final service = widget.service;
    if (service == null || _refreshing) return;
    setState(() => _refreshing = true);
    var reached = 0;
    var failed = 0;
    try {
      // refreshStatus persists the new state into the ledger (and notifies
      // listeners) itself; a single failure (offline, deleted repo) must
      // not block the rest. Records without an open/known PR have nothing
      // to poll — skipping them keeps reached/failed a measure of real
      // network attempts (an early return must never mask an offline
      // cycle, nor fake a reached one).
      for (final publication in widget.ledger.publications) {
        if (publication.prNumber == null) continue;
        try {
          await service.refreshStatus(publication);
          reached++;
        } on Object {
          failed++;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _offline = failed > 0 && reached == 0;
        });
      }
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
          if (_offline)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.wifi_off,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.publicationsOffline,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
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
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    shrinkWrap: true,
                    itemCount: publications.length,
                    itemBuilder: (context, index) =>
                        _PublicationTile(publication: publications[index]),
                  ),
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

class _PublicationTile extends StatefulWidget {
  const _PublicationTile({required this.publication});

  final WidgetPublication publication;

  @override
  State<_PublicationTile> createState() => _PublicationTileState();
}

class _PublicationTileState extends State<_PublicationTile> {
  bool _commentsExpanded = false;

  String get _submittedDate {
    final local = widget.publication.submittedAt.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final publication = widget.publication;
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
                  l10n.publicationSubmittedAt(_submittedDate),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (publication.comments.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  // Reviewer feedback (AC7): plain text only — comment
                  // bodies render as text, never as markdown or remote
                  // content (display-only data, never instructions).
                  InkWell(
                    onTap: () =>
                        setState(() => _commentsExpanded = !_commentsExpanded),
                    child: Text(
                      l10n.publicationComments(publication.comments.length),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                  if (_commentsExpanded)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final comment in publication.comments)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${comment.author}'
                                    ' · ${_commentDate(comment.createdAt)}',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  Text(
                                    comment.body,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
          _StateChip(state: publication.state),
        ],
      ),
    );
  }

  String _commentDate(DateTime utc) {
    final local = utc.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
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
