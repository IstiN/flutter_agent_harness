/// Duration and token formatting shared by trajectory consumers.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// trajectory-record.ts` (`formatDurationMillis`, `formatElapsedSeconds`).
/// Locale-free: labels are fixed strings, thousands are comma-separated.
library;

/// The label used when a value is absent or not finite.
const _unknownLabel = '—';

/// Formats a duration in milliseconds with thousands separators.
///
/// Returns [_unknownLabel] for null, and clamps negative values to zero.
String formatDurationMillis(int? milliseconds) {
  if (milliseconds == null) return _unknownLabel;
  final integer = (milliseconds < 0 ? 0 : milliseconds).toString();
  return integer.replaceAllMapped(_thousands, (match) => ',');
}

/// Formats an elapsed duration given in seconds as a millisecond label.
///
/// Returns [_unknownLabel] for null or non-finite input; negative values
/// clamp to zero.
String formatElapsedSeconds(double? seconds) {
  if (seconds == null || seconds.isNaN || seconds.isInfinite) {
    return _unknownLabel;
  }
  return formatDurationMillis((seconds * 1000).round());
}

/// Formats a token count compactly (`999`, `12.3k`, `1.2M`).
///
/// Returns [_unknownLabel] for null.
String formatTokens(int? tokens) {
  if (tokens == null) return _unknownLabel;
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) return '${_trim(_scale(tokens, 1000))}k';
  return '${_trim(_scale(tokens, 1000000))}M';
}

final RegExp _thousands = RegExp(r'\B(?=(\d{3})+(?!\d))');

double _scale(int value, int unit) => value / unit;

/// Drops a trailing `.0` from a one-decimal compact value.
String _trim(double value) {
  final fixed = value.toStringAsFixed(1);
  return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
}
