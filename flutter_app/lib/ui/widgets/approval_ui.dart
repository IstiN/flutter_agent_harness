import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'agent_service.dart';
import 'l10n/l10n_ext.dart';

/// Renders an approval prompt as a Material dialog — the Flutter/web
/// [ApprovalPrompt] surface. The chat screen installs this on
/// [AgentService.approvalPromptHandler].
///
/// Dismissing the dialog (barrier tap, back button) maps to
/// [ApprovalDecision.deny]: an unanswered prompt must never allow a call.
Future<ApprovalDecision> showApprovalPrompt(
  BuildContext context,
  ApprovalRequest request,
) async {
  final decision = await showDialog<ApprovalDecision>(
    context: context,
    builder: (_) => ApprovalDialog(request: request),
  );
  return decision ?? ApprovalDecision.deny;
}

/// The three-button tool approval dialog: approve once, always allow the
/// tool for the session, or deny. Pops with the chosen [ApprovalDecision],
/// or `null` when dismissed.
class ApprovalDialog extends StatelessWidget {
  const ApprovalDialog({super.key, required this.request});

  /// The approval request being decided.
  final ApprovalRequest request;

  static const _maxArgumentChars = 800;

  String _formattedArguments() {
    var encoded = '';
    try {
      encoded = const JsonEncoder.withIndent('  ').convert(request.arguments);
    } on Object {
      encoded = request.arguments.toString();
    }
    if (encoded.length > _maxArgumentChars) {
      encoded = '${encoded.substring(0, _maxArgumentChars)}…';
    }
    return encoded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(context.l10n.approvalAllowToolTitle(request.toolName)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(request.reason),
              const SizedBox(height: 8),
              Text(
                context.l10n.approvalTierLabel(request.tier.name),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _formattedArguments(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(ApprovalDecision.deny),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          child: Text(context.l10n.approvalDeny),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(ApprovalDecision.approveOnce),
          child: Text(context.l10n.approvalAllowOnce),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(ApprovalDecision.approveAlways),
          child: Text(context.l10n.approvalAlwaysAllow),
        ),
      ],
    );
  }
}

/// The three-segment approval mode selector shown in the settings dialog:
/// `always-ask` prompts for every tool call, `write` prompts for mutating
/// and shell tools, `yolo` allows everything (critical bash patterns still
/// prompt). Bound live to [AgentService.approval].
class ApprovalModeSelector extends StatelessWidget {
  const ApprovalModeSelector({super.key, required this.service});

  /// The service whose approval mode the segments switch.
  final AgentService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.l10n.approvalModeTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ApprovalMode>(
              segments: [
                ButtonSegment(
                  value: ApprovalMode.alwaysAsk,
                  label: Text(context.l10n.approvalModeAlwaysAsk),
                ),
                ButtonSegment(
                  value: ApprovalMode.write,
                  label: Text(context.l10n.approvalModeWrite),
                ),
                ButtonSegment(
                  value: ApprovalMode.yolo,
                  label: Text(context.l10n.approvalModeYolo),
                ),
              ],
              selected: {service.approval.mode},
              onSelectionChanged: (modes) =>
                  service.setApprovalMode(modes.first),
            ),
            const SizedBox(height: 8),
            Text(switch (service.approval.mode) {
              ApprovalMode.alwaysAsk => context.l10n.approvalModeAlwaysAskHint,
              ApprovalMode.write => context.l10n.approvalModeWriteHint,
              ApprovalMode.yolo => context.l10n.approvalModeYoloHint,
            }, style: theme.textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
