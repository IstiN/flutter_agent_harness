// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa_ui/src/strings/fa_ui_strings.dart';

/// The model-id field with the `/models` quick select shared by the
/// connection form, the media slot editor, and the default-chat-model
/// picker: a free-text field whose autocomplete options are the endpoint's
/// model ids, filtered by the typed text (any custom id stays valid).
/// While [loading] the field shows the fetching helper and a spinner.
/// When [fromBundledCatalog] is set the list answered from the bundled
/// offline catalog (the live fetch failed) — a muted note says so. When
/// [emptyReason] is set the endpoint answered no models and NAMED why
/// (gh-1990) — the reason renders under the field instead of a bare
/// empty quick-select.
class ModelIdAutocompleteField extends StatelessWidget {
  const ModelIdAutocompleteField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.models,
    required this.loading,
    this.fromBundledCatalog = false,
    this.emptyReason,
  });

  /// The model id being edited (also receives the picked option).
  final TextEditingController controller;

  /// The field's focus node (drives the quick-select overlay).
  final FocusNode focusNode;

  /// The endpoint's `/models` ids feeding the quick select.
  final List<String> models;

  /// Whether a `/models` fetch is in flight.
  final bool loading;

  /// Whether the list answered from the bundled offline catalog (the live
  /// fetch failed) — shows the provenance note.
  final bool fromBundledCatalog;

  /// Why the endpoint answered no models (gh-1990) — the named failure
  /// branch from the fetch report. Rendered under the field when the
  /// quick-select is empty because the endpoint said why it has nothing.
  final String? emptyReason;

  @override
  Widget build(BuildContext context) {
    final strings = FaUiStrings.of(context);
    final field = RawAutocomplete<String>(
      textEditingController: controller,
      focusNode: focusNode,
      optionsBuilder: (value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return models;
        return models.where((id) => id.toLowerCase().contains(query));
      },
      onSelected: (id) => controller.text = id,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: strings.settingsModelIdLabel,
            helperText: loading ? strings.settingsModelsFetching : null,
            suffixIcon: loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 440),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    title: Text(option),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
    if (!fromBundledCatalog && emptyReason == null) return field;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        field,
        const SizedBox(height: 4),
        if (emptyReason != null)
          Text(
            emptyReason!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        if (fromBundledCatalog)
          Text(
            strings.modelPickerBundledCatalogNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
      ],
    );
  }
}
