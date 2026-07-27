import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/l10n/l10n_ext.dart';

import 'package:fa/services/agent_service.dart';

/// The env var name pattern the Keys settings section enforces; the name
/// field is normalized to uppercase and validated against it.
final RegExp secretNamePattern = RegExp(r'^[A-Z][A-Z0-9_]*$');

/// Renders the `request_secret` tool's credential prompt as a modal bottom
/// sheet — the Flutter/web [RequestSecretCallback] surface. The chat screen
/// installs this on [AgentService.secretRequestHandler]; the service
/// persists a granted value into the Keys store and makes it live for the
/// agent (bash `$NAME`, redaction, the prompt's secret-name list).
///
/// Dismissing the sheet (barrier tap, back button, drag-down, "Not now")
/// resolves with `null`: the tool then reports "the user declined", a
/// non-error result the model reacts to gracefully.
Future<RequestSecretResult?> showSecretRequestSheet(
  BuildContext context,
  String name,
  String reason,
) {
  return showModalBottomSheet<RequestSecretResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SecretRequestSheet(name: name, reason: reason),
  );
}

/// The secret request sheet: a lock icon, the agent's [reason] as body text,
/// a prefilled editable name field (validated, uppercase-normalized) and an
/// obscured value field, with Save / "Not now" controls. Pops with the
/// granted [RequestSecretResult], or `null` when dismissed.
class SecretRequestSheet extends StatefulWidget {
  const SecretRequestSheet({
    super.key,
    required this.name,
    required this.reason,
  });

  /// The env var name the agent asked for; prefills the name field.
  final String name;

  /// Why the agent needs the credential; shown as body text.
  final String reason;

  @override
  State<SecretRequestSheet> createState() => _SecretRequestSheetState();
}

class _SecretRequestSheetState extends State<SecretRequestSheet> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.name,
  );
  final TextEditingController _valueController = TextEditingController();
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim().toUpperCase();
    if (!secretNamePattern.hasMatch(name)) {
      setState(() => _nameError = context.l10n.secretRequestInvalidName);
      return;
    }
    final value = _valueController.text;
    if (value.isEmpty) return;
    Navigator.of(context).pop(RequestSecretResult(name: name, value: value));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.secretRequestTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: context.l10n.secretRequestNotNow,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            if (widget.reason.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(widget.reason, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: context.l10n.secretRequestNameLabel,
                errorText: _nameError,
                isDense: true,
              ),
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [_UpperCaseFormatter()],
              autocorrect: false,
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _valueController,
              decoration: InputDecoration(
                labelText: context.l10n.secretRequestValueLabel,
                isDense: true,
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.secretRequestNotNow),
                ),
                const SizedBox(width: 8),
                ListenableBuilder(
                  listenable: _valueController,
                  builder: (context, _) => FilledButton.icon(
                    onPressed: _valueController.text.isEmpty ? null : _save,
                    icon: const Icon(Icons.key, size: 18),
                    label: Text(context.l10n.secretRequestSave),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Uppercases input as the user types (env var names are UPPER_SNAKE).
final class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
