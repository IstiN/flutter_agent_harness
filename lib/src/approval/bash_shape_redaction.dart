/// Secret-SHAPE redaction for agent-authored `bash` command text (issue
/// #1408 AC3).
///
/// The bench autopsy (run 37736364517, `configure-git-webserver`) recorded
/// the agent's own words: *"The literal key filename got mangled by a
/// filter — I'll use a different key name."* A filter had rewritten text
/// inside a FILENAME the agent was creating; the agent discovered the
/// corruption via I/O errors and planned around a filesystem being edited
/// under it.
///
/// The contract after the fix:
///
/// - ONLY a recognized secret SHAPE — a vendor token regex match (AWS
///   `AKIA…`, GitHub `ghp_…`, OpenAI `sk-…`, JWT, …) — is ever rewritten.
///   Key-like text that matches no shape (random filenames, entropy-heavy
///   identifiers, hex runs) stays byte-identical: agent-authored command
///   text is never touched on a heuristic.
/// - Every forced rewrite produces a [BashCommandRewrite.notice] naming
///   exactly what changed; the bash tool surfaces it in the tool result so
///   the agent sees the rewrite instead of discovering it by failure.
///
/// Pure and synchronous: [layerVendor] does the detection, this module only
/// slices the command around the (non-overlapping, position-sorted)
/// matches.
library;

import '../redact/layer_vendor.dart';
import '../redact/redaction_types.dart';

/// One rewritten span: the matched secret shape and where it sat in the
/// ORIGINAL command text.
final class BashCommandShapeChange {
  /// The change record.
  const BashCommandShapeChange({
    required this.label,
    required this.start,
    required this.end,
  });

  /// The vendor kind label (e.g. `AWS Access Key`) — the name the notice
  /// reports.
  final String label;

  /// Start offset of the original span.
  final int start;

  /// End offset (exclusive) of the original span.
  final int end;
}

/// A rewritten bash command plus the record of every span that changed.
final class BashCommandRewrite {
  /// The rewrite result: [command] is what must execute/persist.
  const BashCommandRewrite({required this.command, required this.changes});

  /// The command text with every recognized secret shape replaced by its
  /// `[REDACTED:<kind>]` marker.
  final String command;

  /// Every rewrite, in command order.
  final List<BashCommandShapeChange> changes;

  /// The tool-result notice naming exactly what changed (issue #1408 AC3):
  /// count plus every rewritten shape's label, in order.
  String get notice {
    final labels = changes.map((change) => change.label).join(', ');
    final n = changes.length;
    return '[bash interceptor rewrote $n secret-shaped value'
        '${n == 1 ? '' : 's'} in the command ($labels) — the executed '
        'command carries the [REDACTED:…] markers; agent-authored text '
        'that is not a recognized secret shape is never rewritten. Pass '
        'the value as an env var (\$NAME) instead of literal text.]';
  }
}

/// Rewrites every recognized secret SHAPE in [command], or null when the
/// command matches none — the common case, and the guarantee: key-like
/// text without a full shape (filenames, identifiers) is never rewritten.
///
/// [config] selects the vendor layer (default: enabled, like the
/// pipeline); a config with the vendor layer disabled yields null.
BashCommandRewrite? redactBashCommandSecretShapes(
  String command, {
  RedactionConfig config = const RedactionConfig(),
}) {
  final trimmed = command.trim();
  if (trimmed.isEmpty || !config.isLayerEnabled(RedactionLayer.vendor)) {
    return null;
  }
  // layerVendor returns non-overlapping matches, but grouped per pattern —
  // sort by position before slicing.
  final matches = layerVendor(command, config)
    ..sort((a, b) => a.start.compareTo(b.start));
  if (matches.isEmpty) return null;
  final buffer = StringBuffer();
  final changes = <BashCommandShapeChange>[];
  var cursor = 0;
  for (final match in matches) {
    buffer
      ..write(command.substring(cursor, match.start))
      ..write('[REDACTED:${match.kindLabel}]');
    changes.add(
      BashCommandShapeChange(
        label: match.kindLabel,
        start: match.start,
        end: match.end,
      ),
    );
    cursor = match.end;
  }
  buffer.write(command.substring(cursor));
  return BashCommandRewrite(command: buffer.toString(), changes: changes);
}
