/// Error raised when a section's snapshot tag does not match the live file
/// content and the edit cannot be applied safely, ported from oh-my-pi
/// `packages/hashline/src/mismatch.ts`.
///
/// Carries enough context to render a useful diagnostic: the anchored lines
/// plus a couple of lines of surrounding context.
library;

import 'format.dart';
import 'messages.dart';

/// Raised when a hashline section's snapshot tag doesn't match the live
/// file's content. The formatted [message] tells the model exactly which
/// tag the file currently hashes to and shows the live content around the
/// anchored lines, so the recovery path is "re-read / re-anchor", never a
/// blind retry.
final class HashlineMismatchError implements Exception {
  /// Creates a mismatch error; [message] is formatted eagerly.
  HashlineMismatchError({
    this.path,
    required this.expectedFileHash,
    required this.actualFileHash,
    required this.fileLines,
    this.anchorLines = const [],
    this.hashRecognized = true,
  }) : message = _formatMessage(
         path,
         expectedFileHash,
         actualFileHash,
         fileLines,
         anchorLines,
         hashRecognized,
       );

  /// The section path, when known.
  final String? path;

  /// The tag the section header cited.
  final String expectedFileHash;

  /// The tag the live file content currently hashes to.
  final String actualFileHash;

  /// The live file's lines (LF-normalized).
  final List<String> fileLines;

  /// The lines the section's edits anchor to.
  final List<int> anchorLines;

  /// `true` when the cited hash resolved to a recorded snapshot (file
  /// content drifted since that snapshot); `false` when no snapshot was
  /// ever recorded for the hash (likely fabricated or carried over from a
  /// prior session).
  final bool hashRecognized;

  /// The formatted diagnostic.
  final String message;

  static List<String> _rejectionHeader(
    String? path,
    String expectedFileHash,
    String actualFileHash,
    bool hashRecognized,
  ) {
    final pathText = path != null ? ' for $path' : '';
    if (!hashRecognized) {
      return [
        'Edit rejected$pathText: hash '
            '$hlFileHashSep$expectedFileHash is not from this session.',
        'The current file hashes to '
            '$hlFileHashSep$actualFileHash. Re-read the file with `read` '
            '(hashline mode) to copy a current '
            '[path${hlFileHashSep}tag] header — never invent the tag and '
            'never reuse one from a prior session.',
      ];
    }
    return [
      'Edit rejected$pathText: file changed between read and edit.',
      'Section is bound to $hlFileHashSep$expectedFileHash, but the '
          'current file hashes to $hlFileHashSep$actualFileHash. If a prior '
          'edit in this session modified this file, copy the '
          '[path${hlFileHashSep}newhash] header from that edit\'s response; '
          'otherwise re-read the file with `read` (hashline mode) to refresh '
          'the tag before retrying.',
    ];
  }

  static String _formatMessage(
    String? path,
    String expectedFileHash,
    String actualFileHash,
    List<String> fileLines,
    List<int> anchorLines,
    bool hashRecognized,
  ) {
    final lines = _rejectionHeader(
      path,
      expectedFileHash,
      actualFileHash,
      hashRecognized,
    );
    final context = formatAnchoredContext(anchorLines, fileLines);
    if (context.isEmpty) return lines.join('\n');
    lines.add('');
    lines.addAll(context);
    return lines.join('\n');
  }

  @override
  String toString() => message;
}
