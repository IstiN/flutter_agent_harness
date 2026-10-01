// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/widget_publication_store.dart';

/// The one state→(label, color) mapping shared by the publications sheet
/// and the per-widget detail sheet (issue #1045 review: the 8-case switch
/// lived in both, drifting apart).
(String, Color) publicationStateVisual(
  WidgetPublicationState state,
  AppLocalizations l10n, {
  bool missing = false,
}) => switch (state) {
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
    missing ? l10n.widgetStatusNotPublished : l10n.publicationStateUnknown,
    Colors.grey,
  ),
  // Publish-lifecycle states: optimistic in-flight attempt, CI validation,
  // verbatim validator failure, and a background failure that outlived the
  // publish sheet.
  WidgetPublicationState.publishing => (l10n.publishInProgress, Colors.blue),
  WidgetPublicationState.validating => (
    l10n.widgetStatusValidating,
    Colors.orange,
  ),
  WidgetPublicationState.invalid => (l10n.widgetStatusInvalid, Colors.red),
  WidgetPublicationState.failed => (l10n.widgetStatusFailed, Colors.red),
};

/// The status chip both publish-status surfaces render.
class PublicationStateChip extends StatelessWidget {
  const PublicationStateChip({
    super.key,
    required this.state,
    this.missing = false,
  });

  final WidgetPublicationState state;

  /// True when the widget has no ledger record at all — rendered from
  /// [WidgetPublicationState.unknown] but labelled "Not published".
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (label, color) = publicationStateVisual(
      state,
      l10n,
      missing: missing,
    );
    return Chip(
      label: Text(label),
      labelStyle: TextStyle(color: color),
      side: BorderSide(color: color),
      backgroundColor: color.withValues(alpha: 0.08),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// The verbatim-failure block both publish-status surfaces render
/// (issue #1045 review r2: validator error lines, a background failure's
/// last error, and the "Open CI run" link lived copy-pasted in the
/// publications sheet and the detail sheet).
class PublicationErrorDetails extends StatelessWidget {
  const PublicationErrorDetails({super.key, required this.publication});

  final WidgetPublication publication;

  /// Whether [publication] has anything this widget would render — the
  /// single mount predicate, so callers never restate the internals.
  static bool matches(WidgetPublication publication) =>
      publication.validatorErrors.isNotEmpty ||
      publication.runHtmlUrl != null ||
      (publication.state == WidgetPublicationState.failed &&
          publication.lastError != null);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The validator's error lines render verbatim, right where the
        // status chip lives — no digging into CI.
        if (publication.validatorErrors.isNotEmpty) ...[
          Text(
            l10n.widgetStatusErrors,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 4),
          // VERBATIM validator output: selectable plain text, never
          // reworded or aggregated — what CI said is what renders.
          SelectableText(
            publication.validatorErrors.join('\n'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
              fontFamily: 'JetBrainsMono',
              height: 1.4,
            ),
          ),
        ],
        if (publication.state == WidgetPublicationState.failed &&
            publication.lastError != null) ...[
          const SizedBox(height: 4),
          SelectableText(
            publication.lastError!,
            maxLines: 6,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (publication.runHtmlUrl != null) ...[
          const SizedBox(height: 2),
          InkWell(
            onTap: () => unawaited(
              launchUrl(
                Uri.parse(publication.runHtmlUrl!),
                mode: LaunchMode.externalApplication,
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
