/// The Decisions API subsystem (gh-1844): OpenRouter's structured
/// decision models (e.g. `inception/mercury-decide:free`,
/// `typesafe/jev-*`).
///
/// A decision model answers TYPED questions about a `state` with
/// CALIBRATED PROBABILITIES instead of free text. The API is NOT
/// OpenAI-chat-compatible — it is served at `{baseUrl}/systemone`
/// (OpenRouter's System One / Decisions API), so this is its own
/// adapter, not a chat dialect flag. There is NO streaming: one request,
/// one JSON response (the non-streaming mapping is deliberate and
/// documented; `decide` never invents a stream where the API has none).
///
/// Provider-adapter discipline:
/// - NO thrown provider errors: every failure — HTTP non-2xx, malformed
///   JSON, local validation — comes back as a structured
///   [DecisionResult.failure] the caller surfaces as-is;
/// - usage accounting when present: [DecisionUsage] parses the
///   response's `usage` block (input/output tokens + cost);
/// - redaction-compatible: the API key rides the `Authorization` header
///   only and never appears in results or error messages.
///
/// Pure Dart: no `dart:io`, fake-HTTP-testable via `http.Client`.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// One typed question about the [state]. The wire discriminator is
/// [type]: `noul` (yes/no probability — the Decisions API's official
/// discriminator per the OpenAPI spec; gh-1844 review), `choice` (pick
/// from a keyed criteria map), `score` (position on an ordered criteria
/// list).
sealed class DecisionQuestion {
  const DecisionQuestion();

  /// The wire `type` discriminator.
  String get type;

  /// What the model is asked to decide (free-form instructions).
  Object? get instructions;

  /// The question's `criteria` block (shape depends on [type]).
  Object? get criteria;

  /// The wire form: `{type, instructions, criteria?}`.
  Map<String, dynamic> toJson() => {
    'type': type,
    if (instructions != null) 'instructions': instructions,
    if (criteria != null) 'criteria': criteria,
  };
}

/// A yes/no question answered with a calibrated probability (`bool`).
final class DecisionBoolQuestion extends DecisionQuestion {
  /// Creates a yes/no question; [criteriaTrue]/[criteriaFalse] sharpen
  /// the calibration by describing each branch.
  const DecisionBoolQuestion({
    required this.instructions,
    this.criteriaTrue,
    this.criteriaFalse,
  });

  /// The wire discriminator: `noul` per the Decisions API OpenAPI spec
  /// (`mapping: {box, choice, noul, score}`) — NOT `bool` (review,
  /// gh-1844: the API 400s every `bool`-discriminated question).
  @override
  String get type => 'noul';

  @override
  final Object? instructions;

  /// Guidance for the `true` branch.
  final Object? criteriaTrue;

  /// Guidance for the `false` branch.
  final Object? criteriaFalse;

  @override
  Object? get criteria => {
    if (criteriaTrue != null) 'true': criteriaTrue,
    if (criteriaFalse != null) 'false': criteriaFalse,
  };
}

/// A pick-one-from-a-fixed-list question (`choice`): the criteria map's
/// KEYS are the allowed answers, its values describe each option.
final class DecisionChoiceQuestion extends DecisionQuestion {
  /// Creates a choice question; [criteria] must be non-empty.
  const DecisionChoiceQuestion({
    required this.instructions,
    required this.criteria,
  });

  @override
  String get type => 'choice';

  @override
  final Object? instructions;

  /// The allowed answers keyed by option id (e.g. `{payments: "..."}`).
  @override
  final Map<String, Object?> criteria;
}

/// A position-on-a-scale question (`score`): the criteria list is the
/// ordered legend (index 0 = lowest), the answer is a calibrated score
/// over that scale.
final class DecisionScoreQuestion extends DecisionQuestion {
  /// Creates a score question; [criteria] must be non-empty.
  const DecisionScoreQuestion({
    required this.instructions,
    required this.criteria,
  });

  @override
  String get type => 'score';

  @override
  final Object? instructions;

  /// The ordered legend, lowest first.
  @override
  final List<Object?> criteria;
}

/// One typed answer with its calibrated probability.
sealed class DecisionAnswer {
  const DecisionAnswer();

  /// The wire `type` discriminator (mirrors the question's).
  String get type;

  /// The wire form (per-answer shape depends on [type]).
  Map<String, dynamic> toJson();
}

/// The answer to a [DecisionBoolQuestion]: [probability] of `true`
/// (1 - probability is the `false` probability).
final class DecisionBoolAnswer extends DecisionAnswer {
  const DecisionBoolAnswer({required this.probability});

  /// The calibrated probability of `true` (0..1).
  final double probability;

  /// The wire discriminator mirrors the question's `noul`.
  @override
  String get type => 'noul';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'noul': probability};
}

/// The answer to a [DecisionChoiceQuestion]: the picked option plus the
/// full calibrated probability distribution over all options.
final class DecisionChoiceAnswer extends DecisionAnswer {
  const DecisionChoiceAnswer({
    required this.choice,
    required this.probabilities,
    this.confidence,
  });

  /// The picked option (one of the question's criteria keys).
  final String choice;

  /// The calibrated probability of every option (0..1 each).
  final Map<String, double> probabilities;

  /// The provider's confidence in the pick, when reported.
  final double? confidence;

  @override
  String get type => 'choice';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'choice': choice,
    if (confidence != null) 'confidence': confidence,
    'probabilities': probabilities,
  };
}

/// The answer to a [DecisionScoreQuestion]: a calibrated score over the
/// question's ordered legend.
final class DecisionScoreAnswer extends DecisionAnswer {
  const DecisionScoreAnswer({
    required this.score,
    required this.probabilities,
    this.confidence,
    this.legend,
  });

  /// The calibrated score (position on the legend's scale).
  final double score;

  /// The calibrated probability of every legend index (keys are the
  /// stringified indices), when reported.
  final Map<String, double> probabilities;

  /// The provider's confidence, when reported.
  final double? confidence;

  /// The echoed legend (index → label), when reported.
  final Map<String, Object?>? legend;

  @override
  String get type => 'score';

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'score': score,
    if (confidence != null) 'confidence': confidence,
    'probabilities': probabilities,
    if (legend != null) 'legend': legend,
  };
}

/// Usage accounting parsed from the response's `usage` block (present on
/// success responses; every field optional because providers may omit).
final class DecisionUsage {
  const DecisionUsage({this.inputTokens, this.outputTokens, this.cost});

  /// Tokens billed for the state + questions.
  final int? inputTokens;

  /// Tokens billed for the answers.
  final int? outputTokens;

  /// Cost in USD, when reported.
  final double? cost;

  /// The wire form; absent fields stay absent.
  Map<String, dynamic> toJson() => {
    if (inputTokens != null) 'input_tokens': inputTokens,
    if (outputTokens != null) 'output_tokens': outputTokens,
    if (cost != null) 'cost': cost,
  };
}

/// The outcome of one Decisions call — NEVER thrown. Provider errors,
/// malformed responses, and local validation failures all land in
/// [DecisionResult.failure]; only programmer errors (null required
/// arguments) throw.
sealed class DecisionResult {
  const DecisionResult();

  /// True on [DecisionSuccess].
  bool get isSuccess => this is DecisionSuccess;

  /// The structured JSON form surfaced to the model/user.
  Map<String, dynamic> toJson();
}

/// The success variant of [DecisionResult].
final class DecisionSuccess extends DecisionResult {
  const DecisionSuccess({
    this.id,
    this.model,
    this.provider,
    required this.answers,
    required this.usage,
  });

  /// The decision/generation id, when reported.
  final String? id;

  /// The resolved model slug, when reported.
  final String? model;

  /// The serving provider, when reported.
  final String? provider;

  /// The typed answers keyed by question name.
  final Map<String, DecisionAnswer> answers;

  /// Usage accounting.
  final DecisionUsage usage;

  @override
  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    if (model != null) 'model': model,
    if (provider != null) 'provider': provider,
    'answers': {for (final e in answers.entries) e.key: e.value.toJson()},
    'usage': usage.toJson(),
  };
}

/// The failure variant of [DecisionResult]: structured, actionable,
/// never thrown.
final class DecisionFailure extends DecisionResult {
  const DecisionFailure({
    this.statusCode,
    this.code,
    required this.message,
    this.validation = false,
  });

  /// The HTTP status of the failing call, when it reached the wire.
  final int? statusCode;

  /// The provider's error code, when parsed.
  final int? code;

  /// The human-readable failure reason (provider message or local
  /// validation text). Never contains the API key.
  final String message;

  /// True when the failure is local request validation (the call never
  /// hit the network).
  final bool validation;

  @override
  Map<String, dynamic> toJson() => {
    'error': {
      if (statusCode != null) 'statusCode': statusCode,
      if (code != null) 'code': code,
      'message': message,
      if (validation) 'validation': true,
    },
  };
}

/// Validates a decisions request BEFORE any network call; returns the
/// failure result on the first problem (never thrown — gh-1844 AC4
/// "validation ... as result").
DecisionFailure? validateDecisionRequest({
  required String model,
  required Object? state,
  required Map<String, DecisionQuestion> questions,
}) {
  if (model.trim().isEmpty) {
    return const DecisionFailure(
      validation: true,
      message: 'model is required (e.g. inception/mercury-decide:free)',
    );
  }
  if (state == null) {
    return const DecisionFailure(
      validation: true,
      message:
          'state is required — the content the questions decide '
          'about (text, JSON object, or array)',
    );
  }
  if (questions.isEmpty) {
    return const DecisionFailure(
      validation: true,
      message: 'at least one question is required',
    );
  }
  for (final entry in questions.entries) {
    if (entry.key.trim().isEmpty) {
      return const DecisionFailure(
        validation: true,
        message: 'question names must be non-empty',
      );
    }
    final question = entry.value;
    if (question is DecisionChoiceQuestion && question.criteria.isEmpty) {
      return DecisionFailure(
        validation: true,
        message:
            'choice question "${entry.key}" needs non-empty criteria '
            '({option: description})',
      );
    }
    if (question is DecisionScoreQuestion && question.criteria.isEmpty) {
      return DecisionFailure(
        validation: true,
        message:
            'score question "${entry.key}" needs a non-empty criteria '
            'list (ordered legend, lowest first)',
      );
    }
  }
  return null;
}

/// The OpenRouter Decisions adapter (`POST {baseUrl}/systemone`).
///
/// The endpoint is OpenRouter-specific: it is NOT OpenAI-chat-compatible,
/// so this stands next to the provider adapters instead of riding a chat
/// dialect flag. All provider outcomes are structured [DecisionResult]s.
final class DecisionsAdapter {
  /// Creates an adapter; [httpClient] is injectable for fake-HTTP tests.
  const DecisionsAdapter({this.httpClient});

  /// The injected client (a fresh short-lived one per call when null).
  final http.Client? httpClient;

  /// The Decisions API path under an OpenRouter-style base URL
  /// (`https://openrouter.ai/api/v1` → `…/systemone`).
  static const String path = '/systemone';

  /// The default OpenRouter base URL.
  static const String defaultBaseUrl = 'https://openrouter.ai/api/v1';

  /// Asks [questions] about [state] with [model]. Local validation
  /// failures return [DecisionFailure] with `validation: true` BEFORE
  /// any network call; provider failures return the parsed
  /// status/code/message; success returns the typed calibrated answers.
  Future<DecisionResult> decide({
    required String model,
    required Object? state,
    required Map<String, DecisionQuestion> questions,
    String baseUrl = defaultBaseUrl,
    required String apiKey,
  }) async {
    final invalid = validateDecisionRequest(
      model: model,
      state: state,
      questions: questions,
    );
    if (invalid != null) return invalid;

    final client = httpClient ?? http.Client();
    http.Response response;
    try {
      response = await client.post(
        Uri.parse('${_trimSlash(baseUrl)}$path'),
        headers: {
          'Content-Type': 'application/json',
          if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': model,
          'state': state,
          'questions': {
            for (final entry in questions.entries)
              entry.key: entry.value.toJson(),
          },
        }),
      );
    } finally {
      if (httpClient == null) client.close();
    }
    return parseDecisionResponse(response.statusCode, response.body);
  }

  /// Parses one Decisions response (2xx success shape or the
  /// `{error: {code, message}}` failure shape). Non-JSON bodies degrade
  /// to a failure naming the HTTP status. Never throws on provider data.
  DecisionResult parseDecisionResponse(int statusCode, String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    if (statusCode < 200 || statusCode >= 300) {
      return _parseFailure(statusCode, decoded);
    }
    if (decoded is! Map<String, dynamic>) {
      return DecisionFailure(
        statusCode: statusCode,
        message: 'decisions response was not a JSON object',
      );
    }
    final answersJson = decoded['answers'];
    if (answersJson is! Map) {
      return DecisionFailure(
        statusCode: statusCode,
        message: 'decisions response carried no answers object',
      );
    }
    final answers = <String, DecisionAnswer>{};
    for (final entry in answersJson.entries) {
      final answer = _parseAnswer(entry.value);
      if (answer == null) {
        return DecisionFailure(
          statusCode: statusCode,
          message:
              'decisions answer "${entry.key}" had an unknown or '
              'malformed shape: ${entry.value}',
        );
      }
      answers[entry.key.toString()] = answer;
    }
    return DecisionSuccess(
      id: decoded['id']?.toString(),
      model: decoded['model']?.toString(),
      provider: decoded['provider']?.toString(),
      answers: answers,
      usage: _parseUsage(decoded['usage']),
    );
  }

  /// The `{error: {code, message}}` failure shape for a non-2xx status;
  /// degrades to the bare HTTP status when the body carries no usable
  /// error object. Extracted from [parseDecisionResponse] to keep its
  /// complexity in the CRAP budget (gh-1844).
  DecisionFailure _parseFailure(int statusCode, Object? decoded) {
    var code = statusCode;
    var message = 'HTTP $statusCode';
    if (decoded is Map && decoded['error'] is Map) {
      final error = decoded['error'] as Map;
      final parsedCode = error['code'];
      if (parsedCode is int) code = parsedCode;
      final parsedMessage = error['message'];
      if (parsedMessage is String && parsedMessage.isNotEmpty) {
        message = parsedMessage;
      }
    }
    return DecisionFailure(
      statusCode: statusCode,
      code: code,
      message: message,
    );
  }

  DecisionAnswer? _parseAnswer(Object? value) {
    if (value is! Map) return null;
    final type = value['type'];
    switch (type) {
      // gh-1844 review: the official discriminator is `noul`; `bool` is
      // kept as a tolerated alias for pre-noul payloads. The probability
      // key accepts either spelling under either discriminator.
      case 'noul':
      case 'bool':
        final probability =
            _asDouble(value['noul']) ?? _asDouble(value['bool']);
        return probability == null
            ? null
            : DecisionBoolAnswer(probability: probability);
      case 'choice':
        final choice = value['choice'];
        if (choice is! String) return null;
        return DecisionChoiceAnswer(
          choice: choice,
          confidence: _asDouble(value['confidence']),
          probabilities: _probabilityMap(value['probabilities']),
        );
      case 'score':
        final score = _asDouble(value['score']);
        if (score == null) return null;
        final legend = value['legend'];
        return DecisionScoreAnswer(
          score: score,
          confidence: _asDouble(value['confidence']),
          probabilities: _probabilityMap(value['probabilities']),
          legend: legend is Map
              ? legend.map((k, v) => MapEntry(k.toString(), v))
              : null,
        );
      default:
        return null;
    }
  }

  DecisionUsage _parseUsage(Object? value) {
    if (value is! Map) return const DecisionUsage();
    return DecisionUsage(
      inputTokens: _asInt(value['input_tokens']),
      outputTokens: _asInt(value['output_tokens']),
      cost: _asDouble(value['cost']),
    );
  }

  static Map<String, double> _probabilityMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (_asDouble(entry.value) != null)
          entry.key.toString(): _asDouble(entry.value)!,
    };
  }

  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  static int? _asInt(Object? value) => value is num ? value.toInt() : null;

  String _trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
