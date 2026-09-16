// l10n:ignore-file — SSO flow screens — en-only by design (EPAM-internal tooling)
import 'package:flutter/material.dart';

import 'package:fa_ui/fa_ui.dart' show FaModelListPicker, pushFaPage;

/// Shows a simple project picker page (dialog on wide, full page on narrow).
/// Purely informational (like the CLI flow) — the selection does not affect
/// auth headers.
Future<void> showCodeMieProjectPicker(
  BuildContext context,
  List<String> projects,
) async {
  await pushFaPage<void>(
    context,
    CodeMieProjectPickerPage(projects: projects, onSelected: (_) {}),
  );
}

/// Shows a model picker page (dialog on wide, full page on narrow) and
/// returns the chosen model id.
///
/// The shared quick-filter pattern ([FaModelListPicker]): the field is the
/// value AND the live filter over the fetched [models]; when the list is
/// empty (fetch failed), a note says the id must be typed manually.
///
/// [preselected] seeds the field with the current model. When [allowCancel]
/// is true, the user can dismiss the page without picking (returns null).
Future<String?> showCodeMieModelPicker(
  BuildContext context,
  List<String> models, {
  String? preselected,
  bool allowCancel = false,
}) {
  return pushFaPage<String>(
    context,
    CodeMieModelPickerPage(
      models: models,
      preselected: preselected,
      allowCancel: allowCancel,
    ),
  );
}

/// The informational project list of the CodeMie sign-in flow (the widget
/// layer owns the pages; the service receives the picked values).
class CodeMieProjectPickerPage extends StatefulWidget {
  const CodeMieProjectPickerPage({
    super.key,
    required this.projects,
    required this.onSelected,
  });

  final List<String> projects;
  final ValueChanged<String> onSelected;

  @override
  State<CodeMieProjectPickerPage> createState() =>
      _CodeMieProjectPickerPageState();
}

class _CodeMieProjectPickerPageState extends State<CodeMieProjectPickerPage> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CodeMie Project')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: widget.projects.length,
                itemBuilder: (context, index) {
                  final project = widget.projects[index];
                  return ListTile(
                    title: Text(project),
                    dense: true,
                    trailing: _selected == project
                        ? const Icon(Icons.check_circle, size: 20)
                        : const Icon(Icons.radio_button_unchecked, size: 20),
                    onTap: () => setState(() => _selected = project),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: () {
                  widget.onSelected(_selected ?? widget.projects.first);
                  Navigator.of(context).pop();
                },
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The model picker of the CodeMie sign-in flow: a quick-filter field over
/// the fetched models plus Connect (and an optional Cancel).
class CodeMieModelPickerPage extends StatefulWidget {
  const CodeMieModelPickerPage({
    super.key,
    required this.models,
    this.preselected,
    this.allowCancel = false,
  });

  final List<String> models;
  final String? preselected;
  final bool allowCancel;

  @override
  State<CodeMieModelPickerPage> createState() => _CodeMieModelPickerPageState();
}

class _CodeMieModelPickerPageState extends State<CodeMieModelPickerPage> {
  late final TextEditingController _modelController;

  @override
  void initState() {
    super.initState();
    _modelController = TextEditingController(text: widget.preselected ?? '');
  }

  @override
  void dispose() {
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Model')),
      body: SafeArea(
        child: Column(
          children: [
            // The same quick-filter pattern every model picker uses: the
            // field is the value AND the live filter over the fetched list.
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: FaModelListPicker(
                  controller: _modelController,
                  models: widget.models,
                  loading: false,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.allowCancel)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  FilledButton(
                    onPressed: () {
                      final id = _modelController.text.trim();
                      Navigator.of(context).pop(id.isNotEmpty ? id : null);
                    },
                    child: const Text('Connect'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
