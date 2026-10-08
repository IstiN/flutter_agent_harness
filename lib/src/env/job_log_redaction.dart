/// Line-buffered secret redaction for background-job log writes at rest
/// (issue #1408 AC2).
///
/// The bench autopsy (run 37736364517, sanitize-git-repo ×2) showed
/// `.fah/bash_jobs/<id>.log` capturing RAW secret values from the agent's
/// own greps inside the graded task workspace: the agent noticed, sanitized
/// its own harness logs, and the extra modified files flipped
/// `test_no_other_files_changed`. The host now pipes every job's output
/// chunks through a [JobLogRedactor] (usually `RedactionPipeline.redact`)
/// BEFORE they reach the log sink, so the resting file carries
/// `[REDACTED:<kind>]` markers instead of secret values — the model's
/// `bash_job output` reads (which tail the file) see the masked text too.
///
/// Chunks arrive as arbitrary stream slices, so a secret token can split
/// across two writes. The redactor buffers the trailing partial line and
/// only sanitizes complete newline-terminated text; [flush] emits the
/// buffered remainder at job settle, so nothing stays trapped in the
/// buffer.
///
/// Pure Dart — no `dart:io`. The transform is injected, so VM hosts (the
/// redaction pipeline) and tests (plain replaceAll) share the exact path.
library;

/// Line-buffered redaction over streamed job-log chunks.
final class JobLogRedactor {
  /// Creates a redactor applying [transform] to every complete line run.
  /// The transform must be idempotent on already-masked text (the
  /// redaction pipeline is; a plain replaceAll is).
  JobLogRedactor(this.transform);

  /// The per-line sanitizer (typically `RedactionPipeline.redact`).
  final String Function(String text) transform;

  /// The trailing partial line, waiting for its newline.
  String _carry = '';

  /// Sanitizes [chunk]: complete lines through [transform] immediately,
  /// the trailing partial line held back until its newline arrives (or
  /// [flush] runs at settle).
  String ingest(String chunk) {
    if (chunk.isEmpty) return '';
    final buffered = _carry + chunk;
    final cut = buffered.lastIndexOf('\n');
    if (cut < 0) {
      _carry = buffered;
      return '';
    }
    _carry = buffered.substring(cut + 1);
    return transform(buffered.substring(0, cut + 1));
  }

  /// Emits the buffered partial line at job settle (sanitized like every
  /// complete line). Empty when the stream ended on a newline.
  String flush() {
    final rest = _carry;
    _carry = '';
    return rest.isEmpty ? '' : transform(rest);
  }
}
