/// Cross-turn usage accumulation for the agent layer.
///
/// Providers report [Usage] per response; the agent loop needs cumulative
/// token and cost totals across all turns of a run (for cost reporting and
/// budget enforcement). [UsageAccumulator] is that sum, kept separate from
/// the immutable per-message [Usage].
library;

import 'types.dart';

/// Mutable accumulator summing [Usage] across turns of an agent run.
///
/// Token fields are summed directly; [Usage.reasoning] and
/// [Usage.cacheWrite1h] are optional per provider, so the accumulated
/// [total] reports them as `null` until at least one added usage reported
/// them. Costs are summed field by field.
final class UsageAccumulator {
  var _input = 0;
  var _output = 0;
  var _cacheRead = 0;
  var _cacheWrite = 0;
  var _cacheWrite1h = 0;
  var _hasCacheWrite1h = false;
  var _reasoning = 0;
  var _hasReasoning = false;
  var _totalTokens = 0;
  var _costInput = 0.0;
  var _costOutput = 0.0;
  var _costCacheRead = 0.0;
  var _costCacheWrite = 0.0;
  var _costTotal = 0.0;
  var _turns = 0;

  /// Number of usages added so far (typically one per assistant turn).
  int get turns => _turns;

  /// Adds one response's [usage] to the running totals.
  void add(Usage usage) {
    _input += usage.input;
    _output += usage.output;
    _cacheRead += usage.cacheRead;
    _cacheWrite += usage.cacheWrite;
    final cacheWrite1h = usage.cacheWrite1h;
    if (cacheWrite1h != null) {
      _cacheWrite1h += cacheWrite1h;
      _hasCacheWrite1h = true;
    }
    final reasoning = usage.reasoning;
    if (reasoning != null) {
      _reasoning += reasoning;
      _hasReasoning = true;
    }
    _totalTokens += usage.totalTokens;
    _costInput += usage.cost.input;
    _costOutput += usage.cost.output;
    _costCacheRead += usage.cost.cacheRead;
    _costCacheWrite += usage.cost.cacheWrite;
    _costTotal += usage.cost.total;
    _turns += 1;
  }

  /// The accumulated totals as an immutable [Usage].
  Usage get total => Usage(
    input: _input,
    output: _output,
    cacheRead: _cacheRead,
    cacheWrite: _cacheWrite,
    cacheWrite1h: _hasCacheWrite1h ? _cacheWrite1h : null,
    reasoning: _hasReasoning ? _reasoning : null,
    totalTokens: _totalTokens,
    cost: UsageCost(
      input: _costInput,
      output: _costOutput,
      cacheRead: _costCacheRead,
      cacheWrite: _costCacheWrite,
      total: _costTotal,
    ),
  );
}
