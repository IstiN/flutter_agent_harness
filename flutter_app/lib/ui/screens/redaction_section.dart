// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/ui/screens/settings_tiles.dart';
import 'package:flutter/material.dart';

/// The settings "Secret redaction" row (issue #1078 AC4/E3): flips the
/// live redaction pipeline — a yaml-configured pipeline re-flips in
/// place; a yaml-disabled boot rebuilds one from the boot secrets
/// snapshot. Local state drives the switch ([AgentService] isn't
/// notified); persistence is the yaml file's job (the CLI owns the
/// editor).
class RedactionSection extends StatefulWidget {
  const RedactionSection({super.key, required this.service});

  /// The service carrying the live pipeline.
  final AgentService service;

  @override
  State<RedactionSection> createState() => _RedactionSectionState();
}

class _RedactionSectionState extends State<RedactionSection> {
  late bool _enabled = widget.service.redactionEnabled;

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchRow(
      value: _enabled,
      onChanged: (enabled) {
        setState(() => _enabled = enabled);
        widget.service.setRedactionEnabled(enabled);
        AppAnalytics.instance.widgetEvent(
          'redaction_toggled',
          params: {'enabled': enabled},
        );
      },
      leading: const Icon(Icons.visibility_off_outlined),
      title: Text(context.l10n.settingsRedaction),
      subtitle: Text(context.l10n.settingsRedactionHint),
    );
  }
}
