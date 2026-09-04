/// L2: known vendor token shapes.
///
/// Every pattern is a distinctive-prefix shape (GitHub, AWS, OpenAI, JWT,
/// GitLab, Slack, Google, npm). [quickScreen] is the cheap `indexOf`
/// pre-screen used by the pipeline and the prefix layer to skip the full
/// regex pass when no prefix is present anywhere in the text.
library;

import 'redaction_types.dart';

/// Marker labels for the vendor layer.
const String githubTokenLabel = 'GitHub Token';
const String awsAccessKeyLabel = 'AWS Access Key';
const String openAIKeyLabel = 'OpenAI Key';
const String jwtLabel = 'JWT';
const String gitLabTokenLabel = 'GitLab Token';
const String slackTokenLabel = 'Slack Token';
const String googleApiKeyLabel = 'Google API Key';
const String npmTokenLabel = 'npm Token';

/// Distinctive prefixes of every vendor pattern, in scan order.
const List<String> vendorPrefixes = [
  'ghp_',
  'gho_',
  'ghu_',
  'ghs_',
  'ghr_',
  'github_pat_',
  'sk-',
  'AKIA',
  'eyJ',
  'glpat-',
  'xox',
  'AIza',
  'npm_',
];

final List<(RegExp, String)> _patterns = [
  (RegExp(r'\bgh[psour]_[A-Za-z0-9]{36}\b'), githubTokenLabel),
  (RegExp(r'\bgithub_pat_[A-Za-z0-9_]{40,}\b'), githubTokenLabel),
  (RegExp(r'\bAKIA[0-9A-Z]{16}\b'), awsAccessKeyLabel),
  (RegExp(r'\bsk-[A-Za-z0-9]{20,}\b'), openAIKeyLabel),
  (RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\b'), jwtLabel),
  (RegExp(r'\bglpat-[A-Za-z0-9_-]{20,}\b'), gitLabTokenLabel),
  (RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{10,}\b'), slackTokenLabel),
  (RegExp(r'\bAIza[0-9A-Za-z_-]{35}\b'), googleApiKeyLabel),
  (RegExp(r'\bnpm_[A-Za-z0-9]{36}\b'), npmTokenLabel),
];

/// Cheap pre-screen: `true` when at least one vendor prefix occurs in
/// [text]. A `false` result guarantees [layerVendor] finds nothing.
bool quickScreen(String text) {
  for (final prefix in vendorPrefixes) {
    if (text.contains(prefix)) return true;
  }
  return false;
}

/// Finds known vendor token shapes in [text].
///
/// Pure function; matches never overlap (first pattern wins a contested
/// span).
List<RedactionMatch> layerVendor(String text, RedactionConfig cfg) {
  if (text.isEmpty || !quickScreen(text)) return const [];
  final matches = <RedactionMatch>[];
  for (final (pattern, label) in _patterns) {
    for (final m in pattern.allMatches(text)) {
      final match = RedactionMatch(
        start: m.start,
        end: m.end,
        layer: RedactionLayer.vendor,
        kindLabel: label,
      );
      if (!matches.any(match.overlaps)) matches.add(match);
    }
  }
  return matches;
}
