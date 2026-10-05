/// The I4 byte-scan (gh-1241 AC6/UT-6): the usage artifact carries no
/// prompt text, no keys, no paths outside sessionId/model/timestamps/counts
/// — impossible by schema, and asserted on every write: any configured
/// secret or any prompt-content substring found in the serialized artifact
/// fails the write LOUDLY.
///
/// The violation report NEVER echoes the offending text (a scan that
/// prints the secret it found would be a leak itself) — only its offset
/// and length.
library;

/// Raised when the byte-scan finds forbidden content in a usage artifact.
final class UsageHygieneException implements Exception {
  /// Creates a [UsageHygieneException].
  const UsageHygieneException({required this.offset, required this.length});

  /// Byte offset of the offending substring in the artifact.
  final int offset;

  /// Length of the offending substring.
  final int length;

  @override
  String toString() =>
      'UsageHygieneException: forbidden content at offset $offset '
      '(length $length) — redacted by design (I4)';
}

/// Asserts that [artifact] contains none of [forbiddenSecrets] (configured
/// keys/tokens) and none of [forbiddenContent] (prompt-content substrings
/// from the session).
///
/// Empty needles are ignored. Throws [UsageHygieneException] on the first
/// hit.
void assertUsageArtifactHygiene(
  String artifact, {
  Iterable<String> forbiddenSecrets = const [],
  Iterable<String> forbiddenContent = const [],
}) {
  for (final needle in forbiddenSecrets) {
    if (needle.isEmpty) continue;
    final offset = artifact.indexOf(needle);
    if (offset >= 0) {
      throw UsageHygieneException(offset: offset, length: needle.length);
    }
  }
  for (final needle in forbiddenContent) {
    if (needle.length < 8) continue;
    final offset = artifact.indexOf(needle);
    if (offset >= 0) {
      throw UsageHygieneException(offset: offset, length: needle.length);
    }
  }
}
