import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'chat_strings.dart';
import 'fa_chat_host.dart';

/// The slice of the chat backend [ApprovalModeSelector] needs: a listenable
/// holding the live [ApprovalManager] plus a mode setter. [FaChatService]
/// already carries both members, so any chat backend satisfies this.
abstract interface class FaApprovalModeController implements Listenable {
  /// The approval manager whose mode the selector reflects.
  ApprovalManager get approval;

  /// Applies a new approval mode.
  void setApprovalMode(ApprovalMode mode);
}

/// Renders an approval prompt as a Material dialog — the Flutter/web
/// [ApprovalPrompt] surface. The host chat screen installs this on
/// [FaChatService.approvalPromptHandler].
///
/// Dismissing the dialog (barrier tap, back button) maps to
/// [ApprovalDecision.deny]: an unanswered prompt must never allow a call.
///
/// When [modeController] is provided the dialog offers a "YOLO mode —
/// allow everything" checkbox: toggling it switches the SESSION approval
/// mode live (toggle off restores the mode the dialog opened with).
Future<ApprovalDecision> showApprovalPrompt(
  BuildContext context,
  ApprovalRequest request, {
  FaApprovalModeController? modeController,
}) async {
  final decision = await showDialog<ApprovalDecision>(
    context: context,
    builder: (_) =>
        ApprovalDialog(request: request, modeController: modeController),
  );
  return decision ?? ApprovalDecision.deny;
}

/// The three-button tool approval dialog: approve once, always allow the
/// tool for the session, or deny. Pops with the chosen [ApprovalDecision],
/// or `null` when dismissed. With a [modeController] it also carries the
/// session-wide yolo checkbox.
class ApprovalDialog extends StatefulWidget {
  const ApprovalDialog({super.key, required this.request, this.modeController});

  /// The approval request being decided.
  final ApprovalRequest request;

  /// Session approval-mode controller behind the yolo checkbox; null
  /// hides the checkbox (the classic three-button dialog).
  final FaApprovalModeController? modeController;

  @override
  State<ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<ApprovalDialog> {
  static const _maxArgumentChars = 800;

  /// The mode the dialog opened with — unchecking yolo restores it.
  ApprovalMode? _previousMode;
  bool _yolo = false;

  @override
  void initState() {
    super.initState();
    final controller = widget.modeController;
    if (controller != null) {
      _previousMode = controller.approval.mode;
      _yolo = _previousMode == ApprovalMode.yolo;
    }
  }

  void _onYoloChanged(bool? checked) {
    final controller = widget.modeController;
    if (controller == null || checked == null) return;
    setState(() => _yolo = checked);
    controller.setApprovalMode(
      checked ? ApprovalMode.yolo : (_previousMode ?? ApprovalMode.alwaysAsk),
    );
  }

  String _formattedArguments() {
    var encoded = '';
    try {
      encoded = const JsonEncoder.withIndent(
        '  ',
      ).convert(widget.request.arguments);
    } on Object {
      encoded = widget.request.arguments.toString();
    }
    if (encoded.length > _maxArgumentChars) {
      encoded = '${encoded.substring(0, _maxArgumentChars)}…';
    }
    return encoded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    return AlertDialog(
      title: Text(
        FaChatStrings.of(context).approvalAllowToolTitle(request.toolName),
      ),
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
                FaChatStrings.of(context).approvalTierLabel(request.tier.name),
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
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ),
              if (widget.modeController != null) ...[
                const SizedBox(height: 4),
                CheckboxListTile(
                  value: _yolo,
                  onChanged: _onYoloChanged,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    FaChatStrings.of(context).approvalYoloAllowEverything,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(ApprovalDecision.deny),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          child: Text(FaChatStrings.of(context).approvalDeny),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(ApprovalDecision.approveOnce),
          child: Text(FaChatStrings.of(context).approvalAllowOnce),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(ApprovalDecision.approveAlways),
          child: Text(FaChatStrings.of(context).approvalAlwaysAllow),
        ),
      ],
    );
  }
}

/// The three-segment approval mode selector shown in the settings dialog:
/// `always-ask` prompts for every tool call, `write` prompts for mutating
/// and shell tools, `yolo` allows everything (critical bash patterns still
/// prompt). Bound live to [FaApprovalModeController.approval].
class ApprovalModeSelector extends StatelessWidget {
  const ApprovalModeSelector({super.key, required this.service});

  /// The service whose approval mode the segments switch.
  final FaApprovalModeController service;

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
              FaChatStrings.of(context).approvalModeTitle,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<ApprovalMode>(
              segments: [
                ButtonSegment(
                  value: ApprovalMode.alwaysAsk,
                  label: Text(FaChatStrings.of(context).approvalModeAlwaysAsk),
                ),
                ButtonSegment(
                  value: ApprovalMode.write,
                  label: Text(FaChatStrings.of(context).approvalModeWrite),
                ),
                ButtonSegment(
                  value: ApprovalMode.yolo,
                  label: Text(FaChatStrings.of(context).approvalModeYolo),
                ),
              ],
              selected: {service.approval.mode},
              onSelectionChanged: (modes) {
                FaChatHost.track('approval_mode_changed', {
                  'mode': modes.first.name,
                });
                service.setApprovalMode(modes.first);
              },
            ),
            const SizedBox(height: 8),
            Text(switch (service.approval.mode) {
              ApprovalMode.alwaysAsk => FaChatStrings.of(
                context,
              ).approvalModeAlwaysAskHint,
              ApprovalMode.write => FaChatStrings.of(
                context,
              ).approvalModeWriteHint,
              ApprovalMode.yolo => FaChatStrings.of(
                context,
              ).approvalModeYoloHint,
              ApprovalMode.unattended => FaChatStrings.of(
                context,
              ).approvalModeYoloHint,
            }, style: theme.textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
