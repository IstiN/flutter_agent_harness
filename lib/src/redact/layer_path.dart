/// L1: credential file paths and credential-file content.
///
/// Two behaviors:
/// 1. when the caller supplies a `pathHint` (the tool's own file path) and
///    that path is a credential file, the whole supplied text is treated as
///    sensitive (one `'Credential File'` span over the entire text);
/// 2. inline detection of credential path tokens mentioned in text
///    (`~/.ssh/id_rsa`, `/home/u/.env`, `.npmrc`, ...) — only the path token
///    itself is masked.
library;

import 'redaction_types.dart';

/// Marker label used for credential-file spans.
const String credentialFileLabel = 'Credential File';

const Set<String> _credentialBaseNames = {
  '.env',
  'id_rsa',
  'id_ed25519',
  'id_ecdsa',
  'id_dsa',
  '.npmrc',
  '.netrc',
};

/// Whether [path] names a credential file.
///
/// Pure string classification — no file system access.
bool isCredentialPath(String path) {
  if (path.isEmpty) return false;
  final normalized = path.replaceAll('\\', '/').toLowerCase();
  final base = normalized.split('/').last;
  if (base == '.env' || base.startsWith('.env.')) return true;
  if (_credentialBaseNames.contains(base)) return true;
  if (base.endsWith('.pem')) return true;
  return normalized.contains('.aws/credentials') ||
      normalized.contains('.ssh/config') ||
      normalized.contains('.docker/config.json');
}

// Dotfile markers must not be preceded by a word character so
// `process.env` stays clean while `project/.env` and bare `.env` match.
final RegExp _inlineCredentialPath = RegExp(
  // A .env token only matches when a PATH SEGMENT precedes it
  // (project/.env, ~/app/.env, ./.env) - a bare
  // .env filename (pubspec asset lists, prose) reveals no secret
  // location and stays visible (over-redaction fix). The other
  // markers keep matching bare: .npmrc, id_rsa & co. are distinct
  // credential names.
  r'(?<![\w.])\.(?:npmrc|netrc|ssh/config|aws/credentials|docker/config\.json)\b'
  r'|(?<![\w.-])id_(?:rsa|ed25519|ecdsa|dsa)\b'
  r'|(?:[\w.~-]+/)+\.env\b(?:\.[a-z0-9_.-]+)?',
  caseSensitive: false,
);

/// Cheap pre-screen so the inline regex pass only runs when one of the
/// credential markers is plausibly present.
const List<String> _inlineMarkers = [
  '.env',
  'id_rsa',
  'id_ed25519',
  'id_ecdsa',
  'id_dsa',
  '.npmrc',
  '.netrc',
  '.pem',
  '.aws/credentials',
  '.ssh/config',
  '.docker/config.json',
];

bool _mightContainCredentialPath(String lowerText) {
  for (final marker in _inlineMarkers) {
    if (lowerText.contains(marker)) return true;
  }
  return false;
}

/// Scans [text] for credential path content.
///
/// When [pathHint] is a credential file path the whole text becomes a single
/// match; otherwise inline credential path tokens are matched individually.
List<RedactionMatch> layerPath(
  String text,
  RedactionConfig cfg, {
  String? pathHint,
}) {
  if (text.isEmpty) return const [];
  if (pathHint != null && isCredentialPath(pathHint)) {
    return [
      RedactionMatch(
        start: 0,
        end: text.length,
        layer: RedactionLayer.path,
        kindLabel: credentialFileLabel,
      ),
    ];
  }
  final lower = text.toLowerCase();
  if (!_mightContainCredentialPath(lower)) return const [];
  final matches = <RedactionMatch>[];
  for (final m in _inlineCredentialPath.allMatches(text)) {
    final match = RedactionMatch(
      start: m.start,
      end: m.end,
      layer: RedactionLayer.path,
      kindLabel: credentialFileLabel,
    );
    if (!matches.any(match.overlaps)) matches.add(match);
  }
  return matches;
}
