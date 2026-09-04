// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Key management dialogs split out of settings.dart (the file-size guard
/// keeps leaf UI files small; these two dialogs are self-contained).
library;

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';

/// Responsive dialog content width: [preferred] on wide screens, shrinking
/// to fit narrow phones (AlertDialog's default inset padding is 16-24 px).
double _dialogContentWidth(BuildContext context, double preferred) {
  final available = MediaQuery.sizeOf(context).width - 32;
  return available < preferred ? available.clamp(0.0, preferred) : preferred;
}

/// Edits one provider key's value (`Set OPENROUTER_API_KEY`).
class KeyEditorDialog extends StatefulWidget {
  const KeyEditorDialog({super.key, required this.title});

  /// Dialog title (`Set OPENROUTER_API_KEY`).
  final String title;

  @override
  State<KeyEditorDialog> createState() => _KeyEditorDialogState();
}

class _KeyEditorDialogState extends State<KeyEditorDialog> {
  final TextEditingController _valueController = TextEditingController();

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: _dialogContentWidth(context, 380),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _valueController,
              decoration: InputDecoration(
                labelText: context.l10n.keysValueLabel,
                hintText: context.l10n.keysValueHint,
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: _save,
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.keysSectionNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        ListenableBuilder(
          listenable: _valueController,
          builder: (context, _) => FilledButton(
            onPressed: _valueController.text.trim().isEmpty
                ? null
                : () => _save(_valueController.text),
            child: Text(context.l10n.settingsSaveButton),
          ),
        ),
      ],
    );
  }

  void _save(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(context).pop(trimmed);
  }
}

/// The add-key dialog opened from [KeysSection]: collects an arbitrary key
/// name (validated against [namePattern], uppercase-normalized, duplicates
/// rejected via [isDuplicate]) plus its (obscured) value. Pops with the
/// `(name, value)` record, or `null` when cancelled.
class AddKeyDialog extends StatefulWidget {
  const AddKeyDialog({super.key, required this.isDuplicate});

  /// The accepted name shape (shell-env style, e.g. `GITHUB_TOKEN`).
  static final RegExp namePattern = RegExp(r'^[A-Z][A-Z0-9_]*$');

  /// Whether a (normalized) name already has a row in the Keys section.
  final bool Function(String name) isDuplicate;

  @override
  State<AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends State<AddKeyDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();

  /// The validation error under the name field; `null` while valid/untried.
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.keysAddDialogTitle),
      content: SizedBox(
        width: _dialogContentWidth(context, 380),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: context.l10n.keysAddNameLabel,
                hintText: context.l10n.keysAddNameHint,
                errorText: _nameError,
              ),
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              onChanged: (_) => setState(() => _nameError = null),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _valueController,
              decoration: InputDecoration(
                labelText: context.l10n.keysValueLabel,
                hintText: context.l10n.keysValueHint,
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_nameController, _valueController]),
          builder: (context, _) => FilledButton(
            onPressed:
                _nameController.text.trim().isEmpty ||
                    _valueController.text.trim().isEmpty
                ? null
                : _save,
            child: Text(context.l10n.settingsSaveButton),
          ),
        ),
      ],
    );
  }

  void _save() {
    final name = _nameController.text.trim().toUpperCase();
    final value = _valueController.text.trim();
    if (value.isEmpty) return;
    if (!AddKeyDialog.namePattern.hasMatch(name)) {
      setState(() => _nameError = context.l10n.keysAddNameInvalid);
      return;
    }
    if (widget.isDuplicate(name)) {
      setState(() => _nameError = context.l10n.keysAddNameDuplicate);
      return;
    }
    Navigator.of(context).pop((name: name, value: value));
  }
}

/// The settings "Media models" section — ADAPTER over the fa_ui
/// `MediaModelsSection` (the rows, the [MediaSlotProviderPickerPage] →
/// [MediaSlotModelPage] flow, and the strings live in the package). Keeps
/// the app's constructor surface ([service] + the AppAnalytics wiring) and
/// the gen-l10n slot labels `model_presets.dart` reuses.
///
/// The store comes from [store] or the nearest [MediaModelsScope]; the whole
/// section hides when no store is available (tests pumping the bare form).
