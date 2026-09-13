/// pi's thinking budget contract, shared by all providers.
///
/// Mechanical Dart port of the thinking-ladder helpers in pi-mono
/// `packages/ai/src/api/simple-options.ts` (issue #273). Same constants, same
/// clamping order, so pi fixes port trivially and the wire behavior stays
/// byte-identical. Lives above provider specifics (the anthropic adapter is
/// the first consumer) so the future google thinking adapters reuse the same
/// ladder instead of growing a second one.
///
/// The invariant these helpers encode: the thinking budget never stacks on
/// top of `max_tokens`. The wire `max_tokens` is the caller's answer budget
/// plus a thinking budget that has been clamped to fit inside the model
/// output ceiling — thinking fits INSIDE `max_tokens`, never on top of it.
library;

import 'dart:math' show max, min;

/// pi's `MIN_ANSWER_TOKENS`: a thinking budget may never squeeze the answer
/// below this many tokens.
const int minAnswerTokens = 1024;

/// pi's `DEFAULT_THINKING_BUDGETS` — the per-level budget ladder.
const Map<String, int> defaultThinkingBudgets = {
  'minimal': 1024,
  'low': 2048,
  'medium': 8192,
  'high': 16384,
};

/// pi's `clampReasoning`: the ladder has no `xhigh`/`max` rung, so they fold
/// to `high`, the ladder's top. Everything else passes through unchanged,
/// including `null` (no thinking requested).
String? clampThinkingLevel(String? level) {
  if (level == 'xhigh' || level == 'max') return 'high';
  return level;
}

/// pi's `thinkingBudgetForLevel`: merged-map lookup on the clamped level.
///
/// `null` level → `0`. Our extension: pi never calls with null because its
/// callers gate on thinking being requested; here a null level means "no
/// thinking requested" and a zero budget is exactly the no-op that makes
/// [adjustMaxTokensForThinking] an identity. Unknown level → [ArgumentError],
/// the same crash pi's `!` produces on a missing key, with a readable
/// message.
int thinkingBudgetForLevel(String? level, [Map<String, int>? customBudgets]) {
  if (level == null) return 0;
  final budgets = {...defaultThinkingBudgets, ...?customBudgets};
  final budget = budgets[clampThinkingLevel(level)];
  if (budget == null) {
    throw ArgumentError.value(level, 'level', 'unknown thinking level');
  }
  return budget;
}

/// pi's `clampThinkingBudgetToAnswerRoom`: the budget may never exceed the
/// output ceiling minus [minAnswerTokens].
int clampThinkingBudgetToAnswerRoom(int thinkingBudget, int ceiling) {
  return min(thinkingBudget, max(0, ceiling - minAnswerTokens));
}

/// pi's `adjustMaxTokensForThinking`: pair the wire `max_tokens` with a
/// thinking budget that fits inside it.
///
/// The wire `max_tokens` is the caller's answer budget PLUS the thinking
/// budget, clamped to the model output ceiling — thinking fits INSIDE the
/// ceiling, never on top of it. `baseMaxTokens == null` sends the model cap
/// as-is (only the budget is computed); `level == null` budgets 0, making
/// the pair the plain `max_tokens` identity.
({int maxTokens, int thinkingBudget}) adjustMaxTokensForThinking({
  int? baseMaxTokens,
  required int modelMaxTokens,
  String? level,
  Map<String, int>? customBudgets,
}) {
  var budget = thinkingBudgetForLevel(level, customBudgets);
  var maxTokens = baseMaxTokens == null
      ? modelMaxTokens
      : min(baseMaxTokens + budget, modelMaxTokens);
  if (maxTokens <= budget) {
    budget = clampThinkingBudgetToAnswerRoom(budget, maxTokens);
  }
  return (maxTokens: maxTokens, thinkingBudget: budget);
}
