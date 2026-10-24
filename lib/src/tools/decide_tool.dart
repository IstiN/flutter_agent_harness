/// The `decide` tool (gh-1844): structured decisions via OpenRouter's
/// Decisions API (`/v1/systemone`).
///
/// A decision model answers TYPED questions (yes-no / choice / score)
/// about a `state` with CALIBRATED PROBABILITIES — not free text. The
/// tool surfaces the answers as structured JSON the model can act on.
///
/// Endpoint resolution is CAPABILITY-driven: the Decisions API is an
/// OpenRouter product, so the tool rides the MAIN connection when (and
/// only when) the main provider is OpenRouter; any other main provider
/// fails with an actionable error before any network call. The model id
/// is a tool argument (e.g. `inception/mercury-decide:free`) — a new
/// decision model works with zero code changes, exactly like every other
/// capability-driven path.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../decisions/decisions.dart';

/// The `decide` tool name.
const decideToolName = 'decide';

/// Builds the `decide` [AgentTool].
///
/// [mainBaseUrl]/[mainProviderKind]/[mainApiKey] are live accessors (the
/// provider switch applies without a restart), same pattern as the media
/// tools.
AgentTool decideTool({
  required String Function() mainBaseUrl,
  required String Function() mainProviderKind,
  required String Function() mainApiKey,
  http.Client? httpClient,
}) {
  return AgentTool(
    name: decideToolName,
    label: decideToolName,
    tier: ApprovalTier.read,
    description:
        'Ask a structured decision model (OpenRouter Decisions API, '
        'e.g. inception/mercury-decide:free) typed questions about a '
        'state and receive calibrated answers as structured JSON: yes-no '
        'questions come back with a probability, choice questions with '
        'the picked option plus per-option probabilities, score '
        'questions with a calibrated score over the ordered legend. '
        'Requires the main connection to be an OpenRouter provider. '
        'Arguments: model (required), state (required — text or JSON), '
        'questions (required — object keyed by question name; each entry '
        'is {type: noul|choice|score, instructions, criteria}).',
    parameters: const {
      'type': 'object',
      'properties': {
        'model': {
          'type': 'string',
          'description':
              'decision model slug, e.g. inception/mercury-decide:free',
        },
        'state': {
          'description':
              'the content the questions decide about: a string, or a '
              'JSON object/array of related context',
        },
        'questions': {
          'type': 'object',
          'description':
              'typed questions keyed by name, e.g. {"is_bug": '
              '{"type": "noul", "instructions": "Is this a defect?", '
              '"criteria": {"true": "...", "false": "..."}}, "team": '
              '{"type": "choice", "instructions": "Which team?", '
              '"criteria": {"frontend": "...", "payments": "..."}}}',
        },
      },
      'required': ['model', 'state', 'questions'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final model = (arguments['model'] as String? ?? '').trim();
      if (!arguments.containsKey('state')) {
        return ToolExecutionResult.text(
          jsonEncode(
            const DecisionFailure(
              validation: true,
              message: 'state is required',
            ).toJson(),
          ),
        );
      }
      final state = arguments['state'];
      final questionsArg = arguments['questions'];
      if (questionsArg is! Map) {
        return ToolExecutionResult.text(
          jsonEncode(
            const DecisionFailure(
              validation: true,
              message:
                  'questions must be an object keyed by question '
                  'name',
            ).toJson(),
          ),
        );
      }
      final questions = <String, DecisionQuestion>{};
      DecisionFailure? parseFailure;
      for (final entry in questionsArg.entries) {
        final parsed = _parseQuestion(entry.value);
        if (parsed == null) {
          parseFailure = DecisionFailure(
            validation: true,
            message:
                'question "${entry.key}" must be an object with a '
                'type of noul, choice, or score (and instructions)',
          );
          break;
        }
        questions[entry.key.toString()] = parsed;
      }
      if (parseFailure != null) {
        return ToolExecutionResult.text(jsonEncode(parseFailure.toJson()));
      }

      // Capability gate: the Decisions API is OpenRouter-only. A
      // non-OpenRouter main connection fails HERE, before any network
      // call — capability-driven, never model-name-driven.
      final provider = mainProviderKind();
      if (provider != 'openrouter') {
        return ToolExecutionResult.text(
          jsonEncode(
            DecisionFailure(
              validation: true,
              message:
                  'the Decisions API is served by OpenRouter, but '
                  'the main connection provider is "$provider" — connect '
                  'an OpenRouter provider to use decide',
            ).toJson(),
          ),
        );
      }

      final adapter = DecisionsAdapter(httpClient: httpClient);
      final result = await adapter.decide(
        model: model,
        state: state,
        questions: questions,
        baseUrl: mainBaseUrl(),
        apiKey: mainApiKey(),
      );
      cancelToken?.throwIfCancelled();
      return ToolExecutionResult.text(jsonEncode(result.toJson()));
    },
  );
}

/// Parses one tool-argument question entry into a [DecisionQuestion];
/// null when the shape is unusable (the caller reports it as a
/// validation failure).
DecisionQuestion? _parseQuestion(Object? value) {
  if (value is! Map) return null;
  final type = value['type'];
  final instructions = value['instructions'];
  switch (type) {
    case 'noul':
      final criteria = value['criteria'];
      final map = criteria is Map ? criteria : const <Object?, Object?>{};
      return DecisionNoulQuestion(
        instructions: instructions,
        criteriaTrue: map['true'],
        criteriaFalse: map['false'],
      );
    case 'choice':
      final criteria = value['criteria'];
      if (criteria is! Map) return null;
      return DecisionChoiceQuestion(
        instructions: instructions,
        criteria: criteria.map((k, v) => MapEntry(k.toString(), v)),
      );
    case 'score':
      final criteria = value['criteria'];
      if (criteria is! List) return null;
      return DecisionScoreQuestion(
        instructions: instructions,
        criteria: List<Object?>.from(criteria),
      );
    default:
      return null;
  }
}
