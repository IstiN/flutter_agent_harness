// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa_ui/src/strings/fa_ui_strings.dart';

/// The ONE model-picking pattern for the settings surfaces (media slots,
/// agent/task roles, provider forms): a model-id field whose text doubles
/// as the quick-search query, with the endpoint's fetched list rendered
/// right under it — visible immediately, narrowed live as the user types.
///
/// Manual entry stays first-class: any typed id is valid (the field IS the
/// value), and a `Use "<query>"` row shows whenever the query has no exact
/// match in the list so the escape is discoverable. When the endpoint
/// listed nothing (fetch failed or genuinely empty), a note says the id
/// must be typed manually.
class FaModelListPicker extends StatefulWidget {
  const FaModelListPicker({
    super.key,
    required this.controller,
    required this.models,
    required this.loading,
    this.label,
    this.focusNode,
  });

  /// The model id being edited — its text is also the list filter.
  final TextEditingController controller;

  /// The endpoint's fetched model ids (empty while unfetched or on
  /// failure).
  final List<String> models;

  /// Whether the `/models` fetch is in flight.
  final bool loading;

  /// Field label override; defaults to the shared "Model id" string.
  final String? label;

  /// Optional focus node for the field.
  final FocusNode? focusNode;

  @override
  State<FaModelListPicker> createState() => _FaModelListPickerState();
}

class _FaModelListPickerState extends State<FaModelListPicker> {
  /// Whether the field text is a chosen VALUE (the initial model, or a list
  /// tap) rather than a search query: the list then renders in full with a
  /// check on the match instead of being narrowed by the text.
  var _treatAsSelection = true;

  @override
  void initState() {
    super.initState();
    // Typing re-filters the list (and shows/hides the manual row).
    widget.controller.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onQueryChanged);
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() {
      if (!_selfPick) _treatAsSelection = false;
    });
  }

  /// Set while the widget itself writes a tapped id into the controller —
  /// that change is a pick, not a query edit.
  var _selfPick = false;

  void _pick(String id) {
    _selfPick = true;
    _treatAsSelection = true;
    widget.controller.text = id;
    _selfPick = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = FaUiStrings.of(context);
    final query = widget.controller.text.trim();
    final filtering = !_treatAsSelection && query.isNotEmpty;
    final filtered = !filtering
        ? widget.models
        : widget.models
              .where((id) => id.toLowerCase().contains(query.toLowerCase()))
              .toList();
    final exactMatch = widget.models.any((id) => id == query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          decoration: InputDecoration(
            labelText: widget.label ?? strings.settingsModelIdLabel,
            helperText: widget.loading ? strings.settingsModelsFetching : null,
            suffixIcon: widget.loading
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
        ),
        const SizedBox(height: 8),
        if (!widget.loading && widget.models.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              strings.modelPickerNoEndpointModels,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                if (query.isNotEmpty && !exactMatch)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.edit_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(
                      strings.modelPickerUseManual(query),
                      overflow: TextOverflow.ellipsis,
                    ),
                    // The typed text already IS the value — the row exists
                    // for discoverability, so tapping it just confirms.
                    onTap: () {},
                  ),
                for (final id in filtered)
                  ListTile(
                    dense: true,
                    title: Text(id, overflow: TextOverflow.ellipsis),
                    trailing: id == query
                        ? Icon(
                            Icons.check,
                            size: 18,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                    onTap: () => _pick(id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
