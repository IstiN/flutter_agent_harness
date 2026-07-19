/// Hashline line-prefix handling for body rows pasted from read output,
/// ported from oh-my-pi `packages/hashline/src/prefixes.ts` (single-strip
/// variant only).
library;

/// Matches one leading hashline line-number prefix: `123:`, `>>> 123:`,
/// `+ 123:`, etc.
final _hlPrefixRe = RegExp(r'^\s*(?:>>>|>>)?\s*(?:[+*-]\s*)?\d+:');

/// Strips at most one leading hashline prefix (`N:`, `>>>N:`, `+N:` etc.)
/// from [line] and does NOT loop. Used when the input carries at most one
/// snapshot prefix (e.g. a bare body row pasted from `read` output) —
/// recursive stripping would corrupt content whose own text starts with
/// `digits:`.
String stripOneLeadingHashlinePrefix(String line) {
  return line.replaceFirst(_hlPrefixRe, '');
}
