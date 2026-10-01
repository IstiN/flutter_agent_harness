// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/widget_publication_store.dart';

/// The one state→(label, color) mapping shared by the publications sheet
/// and the per-widget detail sheet (issue #1045 review: the 8-case switch
/// lived in both, drifting apart).
(
  String,
  Color,
)
    publicationStateVisual(
  WidgetPublicationState state,
  AppLocalizations l10n, {
  bool missing = false,
}) => switch (state) {
  WidgetPublicationState.open => (l10n.publicationStateOpen, Colors.blue),
  WidgetPublicationState.published => (
    l10n.publicationStatePublished,
    Colors.green,
  ),
  WidgetPublicationState.rejected => (l10n.publicationStateRejected, Colors.red),
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
  const PublicationStateChip({super.key, required this.state, this.missing});

  final WidgetPublicationState state;

  /// True when the widget has no ledger record at all — rendered from
  /// [WidgetPublicationState.unknown] but labelled "Not published".
  final bool? missing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (label, color) = publicationStateVisual(
      state,
      l10n,
      missing: missing ?? false,
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
