// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart';

/// The settings "Built-in skills" rows (issue #1151): one live switch per
/// skill compiled into the fa package itself ([builtinSkills] —
/// `create-goal`, `self-settings`). Toggling persists via
/// `SkillsTogglesStore` and re-discovers the prompt's skills section live
/// through [AgentService.setSkillToggle] — same shape as the tools rows.
/// The builtins are embedded package data on every host, so the section
/// renders unconditionally (unlike the third-party consent row above it).
class SkillsTogglesSection extends StatelessWidget {
  const SkillsTogglesSection({super.key, required this.service});

  /// The service carrying (and persisting) the toggles.
  final AgentService service;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final skills = builtinSkills();
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_outlined, size: 20, color: colors.dim),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.settingsSkillsToggles,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        context.l10n.settingsSkillsTogglesHint,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.dim),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            for (final skill in skills)
              SwitchListTile(
                value: service.isSkillEnabled(skill.name),
                onChanged: (enabled) =>
                    unawaited(service.setSkillToggle(skill.name, enabled)),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  skill.name,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                subtitle: Text(
                  skill.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
