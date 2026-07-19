/// The `ask` tool: structured mid-turn questions to the user, answered by
/// the host UI through an injectable [AskCallback] — the same host-callback
/// pattern as the approval gate's `ApprovalPrompt` (see `lib/src/approval/`).
///
/// Ported from oh-my-pi's ask tool (`packages/coding-agent/src/tools/ask.ts`
/// + `docs/tools/ask.md`), reduced to the core interaction: the model emits
/// one or more questions with labeled options (optional multi-select and a
/// recommended option), the host UI answers via picker or free text, and the
/// answers serialize back into the transcript as plain text.
///
/// Deliberate divergences from the TypeScript original:
///
/// - No per-question `id`: answers correlate to questions by order and text.
/// - `multi` is spelled `multiSelect`; `recommended` accepts a 0-based index
///   OR an exact option label (omp takes the index only).
/// - `options` may be omitted for a free-form question (omp requires the
///   array; both rely on the host appending a free-text affordance).
/// - Cancellation is a plain (non-error) result — "ask cancelled by user" —
///   so the model continues gracefully (omp throws `ToolAbortError`).
/// - A `null` [AskCallback] (headless host) throws, which the agent loop
///   converts into an ERROR tool result telling the model this host cannot
///   answer questions — omp's `AskTool.createIf` headless guard as a runtime
///   fallback.
/// - omp's timeout auto-select, "Chat about this" redirect, notes, TTS, and
///   terminal notifications are not ported.
library;

import 'dart:async';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../cancel_token.dart';
import '../prompts/prompts.g.dart';

/// One selectable option of an [AskQuestion].
final class AskOption {
  /// Creates an option with a display [label] and optional explanatory
  /// [description] (rendered with the label by the host).
  const AskOption({required this.label, this.description});

  /// The display label; returned verbatim in the answer when selected.
  final String label;

  /// Optional explanatory text shown with the label.
  final String? description;
}

/// One structured question for the host's [AskCallback].
final class AskQuestion {
  /// Creates a question. An empty [options] list marks a free-form question
  /// (the host shows a text field only).
  const AskQuestion({
    required this.question,
    this.options = const [],
    this.multiSelect = false,
    this.recommended,
  });

  /// The question text shown to the user.
  final String question;

  /// The picker options; empty for a free-form answer.
  final List<AskOption> options;

  /// Whether the user may select several options.
  final bool multiSelect;

  /// The 0-based index of the recommended option (the host renders a
  /// "Recommended" badge), or `null` when none was given or the given
  /// index/label did not resolve.
  final int? recommended;
}

/// The user's answer to one [AskQuestion]: selected option labels and/or
/// free text.
final class AskAnswer {
  /// Creates an answer with [selected] labels and/or [freeText].
  const AskAnswer({this.selected = const [], this.freeText});

  /// Creates an answer from selected option [labels].
  const AskAnswer.selection(List<String> labels) : this(selected: labels);

  /// Creates a free-text answer.
  const AskAnswer.text(String text) : this(freeText: text);

  /// Labels of the chosen options (empty when none).
  final List<String> selected;

  /// Free-text input, or `null` when the user picked from the options only.
  final String? freeText;
}

/// Answers [questions] on behalf of the user — the host UI surface (CLI
/// menu, Flutter sheet). Returns one [AskAnswer] per question, or `null`
/// when the user cancels (dismiss/escape): the tool then resolves with an
/// "ask cancelled by user" result so the model continues gracefully.
typedef AskCallback =
    Future<List<AskAnswer>?> Function(List<AskQuestion> questions);

/// Creates the `ask` tool bound to [callback].
///
/// When [callback] is `null` (headless/non-interactive host), executing the
/// tool throws — the agent loop converts it into an error tool result
/// telling the model this host cannot answer questions (the safe fallback).
///
/// The tool forces its tool-call batch to [ToolExecutionMode.sequential]
/// (omp's `concurrency = "exclusive"`): concurrent ask calls would clobber
/// the host's single question surface.
AgentTool askTool({AskCallback? callback}) {
  return AgentTool(
    name: 'ask',
    label: 'ask',
    tier: ApprovalTier.read,
    executionMode: ToolExecutionMode.sequential,
    description: askToolDescriptionPrompt,
    parameters: const {
      'type': 'object',
      'properties': {
        'questions': {
          'type': 'array',
          'description': 'Questions to ask the user (at least one)',
          'items': {
            'type': 'object',
            'properties': {
              'question': {
                'type': 'string',
                'description': 'Question text shown to the user',
              },
              'options': {
                'type': 'array',
                'description':
                    'Picker options (2-5 concise, distinct options); omit '
                    'for a free-form answer',
                'items': {
                  'type': 'object',
                  'properties': {
                    'label': {
                      'type': 'string',
                      'description': 'Short display label',
                    },
                    'description': {
                      'type': 'string',
                      'description':
                          'Optional explanatory text shown with the label',
                    },
                  },
                  'required': ['label'],
                },
              },
              'multiSelect': {
                'type': 'boolean',
                'description': 'Allow multiple selections (default: false)',
              },
              'recommended': {
                'type': ['integer', 'string'],
                'description':
                    'Recommended option: 0-based index or exact label; '
                    'rendered as a "Recommended" badge',
              },
            },
            'required': ['question'],
          },
        },
      },
      'required': ['questions'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final questions = _parseQuestions(arguments['questions']);
      final ask = callback;
      if (ask == null) {
        throw StateError(
          'This host cannot answer questions interactively (no ask UI is '
          'installed). Ask the user in plain text instead.',
        );
      }
      final answers = await _awaitAnswers(ask, questions, cancelToken);
      if (answers == null) {
        return ToolExecutionResult.text(
          'The user cancelled the question dialog without answering. '
          'Proceed with a reasonable default, or ask in plain text if the '
          'input is critical.',
        );
      }
      return ToolExecutionResult.text(_formatAnswers(questions, answers));
    },
  );
}

/// Awaits the host's answers, unblocking promptly with [CancelledException]
/// when the run is aborted while the host still waits for input.
Future<List<AskAnswer>?> _awaitAnswers(
  AskCallback ask,
  List<AskQuestion> questions,
  CancelToken? cancelToken,
) {
  final answers = ask(questions);
  if (cancelToken == null) return answers;
  final cancelled = cancelToken.onCancel.then<List<AskAnswer>?>(
    (_) => throw CancelledException(cancelToken.cancelReason),
  );
  return Future.any([answers, cancelled]);
}

List<AskQuestion> _parseQuestions(Object? raw) {
  if (raw is! List || raw.isEmpty) {
    throw StateError('questions must be a non-empty list');
  }
  return [for (final entry in raw) _parseQuestion(entry)];
}

AskQuestion _parseQuestion(Object? raw) {
  if (raw is! Map) {
    throw StateError('each question must be an object');
  }
  final question = raw['question'];
  if (question is! String || question.trim().isEmpty) {
    throw StateError('each question needs a non-empty "question" text');
  }
  final options = <AskOption>[];
  final rawOptions = raw['options'];
  if (rawOptions != null) {
    if (rawOptions is! List) {
      throw StateError('"options" must be a list');
    }
    for (final rawOption in rawOptions) {
      if (rawOption is! Map || rawOption['label'] is! String) {
        throw StateError('each option needs a "label"');
      }
      final description = rawOption['description'];
      options.add(
        AskOption(
          label: rawOption['label'] as String,
          description: description is String ? description : null,
        ),
      );
    }
  }
  return AskQuestion(
    question: question,
    options: options,
    multiSelect: raw['multiSelect'] == true,
    recommended: _resolveRecommended(raw['recommended'], options),
  );
}

/// Resolves `recommended` (0-based index or exact label) to an option index;
/// invalid values are ignored (omp semantics: it is a UI hint only).
int? _resolveRecommended(Object? raw, List<AskOption> options) {
  final index = switch (raw) {
    num number => number.toInt(),
    String label => options.indexWhere((option) => option.label == label),
    _ => -1,
  };
  return index >= 0 && index < options.length ? index : null;
}

/// Serializes the answers as plain text for the transcript (omp's format:
/// per question, the chosen labels or the free-text input).
String _formatAnswers(List<AskQuestion> questions, List<AskAnswer> answers) {
  if (questions.length == 1) {
    return _formatSingle(answers.isEmpty ? const AskAnswer() : answers.first);
  }
  final lines = <String>['User answers:'];
  for (var i = 0; i < questions.length; i++) {
    final answer = i < answers.length ? answers[i] : const AskAnswer();
    lines.add('${i + 1}. ${questions[i].question}: ${_formatBrief(answer)}');
  }
  return lines.join('\n');
}

/// Single-question format (omp): `User selected: ...` and/or
/// `User provided custom input: ...`.
String _formatSingle(AskAnswer answer) {
  final parts = <String>[];
  if (answer.selected.isNotEmpty) {
    parts.add('User selected: ${answer.selected.join(', ')}');
  }
  final freeText = answer.freeText;
  if (freeText != null && freeText.trim().isNotEmpty) {
    parts.add(
      freeText.contains('\n')
          ? 'User provided custom input:\n'
                '${freeText.split('\n').map((line) => '  $line').join('\n')}'
          : 'User provided custom input: $freeText',
    );
  }
  return parts.isEmpty
      ? 'The user did not answer the question.'
      : parts.join('\n');
}

/// One-line per-question format for multi-question answers: `[a, b]` for
/// multi-select, the bare label for single-select, `"text"` for free input.
String _formatBrief(AskAnswer answer) {
  final parts = <String>[
    if (answer.selected.length > 1)
      '[${answer.selected.join(', ')}]'
    else if (answer.selected.isNotEmpty)
      answer.selected.first,
  ];
  final freeText = answer.freeText;
  if (freeText != null && freeText.trim().isNotEmpty) {
    parts.add('"$freeText"');
  }
  return parts.isEmpty ? '(no answer)' : parts.join(' ');
}
