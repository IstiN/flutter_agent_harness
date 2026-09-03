// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:flutter/material.dart';

/// The settings "Tools" section (issue #19 AC4/AC17): one row per known
/// tool id with a live switch. Toggling calls
/// [AgentService.setToolEnabled], which re-applies the availability
/// resolution to the running agent — the tool list and prompt update
/// without a restart, and the choice persists via `ToolsAvailabilityStore`.
///
/// Rows for ids the app cannot wire stay disabled and show the
/// capability's reason: config can only turn present tools off.
class ToolsAvailabilitySection extends StatelessWidget {
  const ToolsAvailabilitySection({super.key, required this.service});

  /// The service carrying (and persisting) the tool availability.
  final AgentService service;

  @override
  Widget build(BuildContext context) {
    final colors = faui.FahColors.of(context);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final availability = service.toolAvailability;
        final ids = availability.keys.toList()..sort();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune, size: 20, color: colors.dim),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.toolsAvailabilityTitle,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        context.l10n.toolsAvailabilityHint,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            for (final id in ids)
              SwitchListTile(
                value: availability[id]!.enabled,
                // Absent capabilities cannot be enabled — the hard floor.
                onChanged: availability[id]!.capabilityPresent
                    ? (enabled) =>
                          unawaited(service.setToolEnabled(id, enabled))
                    : null,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(id, style: Theme.of(context).textTheme.bodyMedium),
                subtitle: availability[id]!.capabilityPresent
                    ? null
                    : Text(
                        context.l10n.toolsAvailabilityUnavailable(
                          availability[id]!.reason ?? '',
                        ),
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.dim),
                      ),
              ),
          ],
        );
      },
    );
  }
}
