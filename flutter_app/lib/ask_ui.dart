import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/l10n/l10n_ext.dart';

import 'agent_service.dart';

/// Renders the ask tool's questions as a modal bottom sheet — the
/// Flutter/web [AskCallback] surface. The chat screen installs this on
/// [AgentService.askHandler].
///
/// Dismissing the sheet (barrier tap, back button, drag-down, Cancel)
/// resolves with `null`: the tool then reports "ask cancelled by user", a
/// non-error result the model reacts to gracefully.
Future<List<AskAnswer>?> showAskSheet(
  BuildContext context,
  List<AskQuestion> questions,
) {
  return showModalBottomSheet<List<AskAnswer>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AskSheet(questions: questions),
  );
}

/// The answer sheet: one page per question with the option list (radio for
/// single-select, checkboxes for multi-select), a "Recommended" badge on
/// the recommended option, a free-text "Other" field, and
/// Cancel/Back/Next/Answer controls. Pops with one [AskAnswer] per
/// question, or `null` when cancelled.
class AskSheet extends StatefulWidget {
  const AskSheet({super.key, required this.questions});

  /// The questions to answer, in order.
  final List<AskQuestion> questions;

  @override
  State<AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<AskSheet> {
  late final List<_AskDraft> _drafts = [
    for (final question in widget.questions) _AskDraft(question),
  ];
  var _index = 0;

  _AskDraft get _draft => _drafts[_index];
  bool get _isLast => _index == _drafts.length - 1;

  void _advance() {
    if (!_draft.hasAnswer) return;
    if (_isLast) {
      Navigator.of(
        context,
      ).pop([for (final draft in _drafts) draft.toAnswer()]);
    } else {
      setState(() => _index++);
    }
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = _draft.question;
    final total = widget.questions.length;
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
                Expanded(
                  child: Text(
                    total > 1
                        ? context.l10n.askQuestionProgress(
                            (_index + 1).toString(),
                            total.toString(),
                          )
                        : context.l10n.askQuestionTitle,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: context.l10n.askCancel,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Text(question.question, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (question.options.isEmpty)
              _otherField(context.l10n.askYourAnswerLabel)
            else if (question.multiSelect) ...[
              for (var i = 0; i < question.options.length; i++)
                CheckboxListTile(
                  value: _draft.checked.contains(i),
                  onChanged: (checked) => setState(() {
                    if (checked ?? false) {
                      _draft.checked.add(i);
                    } else {
                      _draft.checked.remove(i);
                    }
                  }),
                  title: _optionLabel(i),
                  subtitle: _optionDescription(i),
                ),
              _otherField(context.l10n.askOtherLabel),
            ] else
              RadioGroup<int>(
                groupValue: _draft.radioIndex,
                onChanged: (value) => setState(() => _draft.radioIndex = value),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < question.options.length; i++)
                      RadioListTile<int>(
                        value: i,
                        title: _optionLabel(i),
                        subtitle: _optionDescription(i),
                      ),
                    RadioListTile<int>(
                      value: _AskDraft.otherIndex,
                      title: Text(context.l10n.askOtherLabel),
                    ),
                    if (_draft.radioIndex == _AskDraft.otherIndex)
                      _otherField(context.l10n.askYourAnswerLabel),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.l10n.askCancel),
                ),
                if (_index > 0)
                  TextButton(
                    onPressed: () => setState(() => _index--),
                    child: Text(context.l10n.askBack),
                  ),
                const SizedBox(width: 8),
                ListenableBuilder(
                  listenable: _draft.otherController,
                  builder: (context, _) => FilledButton(
                    onPressed: _draft.hasAnswer ? _advance : null,
                    child: Text(
                      _isLast
                          ? context.l10n.askAnswerAction
                          : context.l10n.askNext,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The option label plus a compact "Recommended" badge when the question
  /// marks this index as recommended (omp's badge).
  Widget _optionLabel(int index) {
    final option = _draft.question.options[index];
    if (_draft.question.recommended != index) return Text(option.label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(option.label)),
        const SizedBox(width: 8),
        Chip(
          label: Text(context.l10n.askRecommended),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }

  Widget? _optionDescription(int index) {
    final description = _draft.question.options[index].description?.trim();
    if (description == null || description.isEmpty) return null;
    return Text(description);
  }

  Widget _otherField(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TextField(
        controller: _draft.otherController,
        decoration: InputDecoration(labelText: label, isDense: true),
        minLines: 1,
        maxLines: 3,
      ),
    );
  }
}

/// The in-progress answer for one question: picked option index (single
/// select), checked indices (multi select), and/or the free-text field.
class _AskDraft {
  _AskDraft(this.question);

  /// [radioIndex] value marking the "Other (type your own)" entry.
  static const otherIndex = -1;

  final AskQuestion question;
  final Set<int> checked = {};
  int? radioIndex;
  final TextEditingController otherController = TextEditingController();

  /// Whether the draft can be submitted: a selection, or non-empty text
  /// when the answer is (or includes) free text.
  bool get hasAnswer {
    final other = otherController.text.trim();
    if (question.options.isEmpty) return other.isNotEmpty;
    if (question.multiSelect) return checked.isNotEmpty || other.isNotEmpty;
    if (radioIndex == otherIndex) return other.isNotEmpty;
    return radioIndex != null;
  }

  /// Maps the draft to the tool's answer: selected labels and/or free text.
  AskAnswer toAnswer() {
    final other = otherController.text.trim();
    if (question.options.isEmpty || radioIndex == otherIndex) {
      return AskAnswer.text(other);
    }
    if (question.multiSelect) {
      return AskAnswer(
        selected: [
          for (final i in checked.toList()..sort()) question.options[i].label,
        ],
        freeText: other.isEmpty ? null : other,
      );
    }
    return AskAnswer.selection([question.options[radioIndex!].label]);
  }

  void dispose() => otherController.dispose();
}
