/// Automatic tool-result spilling (issue #678): an oversized tool result is
/// written to `.fah/spills/<sessionId>/<n>.txt` and the session + the model
/// both see the SAME bounded preview (head + tail + spill path + size stats)
/// — symmetric preview, no "body now, preview later" asymmetry.
///
/// Spill point = the `afterToolCall` hook tier, attached AFTER
/// [attachRedactionPipeline] so the hook chain runs result → redact → size
/// check → spill → preview. Raw secrets never reach this layer (they were
/// masked upstream) and never touch disk.
///
/// Pure Dart: all filesystem work goes through [ExecutionEnv] (no dart:io),
/// so the store is testable with [MemoryExecutionEnv] and sandbox-clamped
/// with the cube env — a refused spill write degrades to the inline
/// fallback, never a crash.
///
/// Kill-switch: `spills.enabled: false` (or `threshold: 0`) means the hook
/// is never attached — byte-identical legacy behavior.
// ignore_for_file: prefer_initializing_formals
library;

import 'dart:convert';

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../env/execution_env.dart';
import '../types.dart';

/// The smallest preview excerpt bound accepted from config. A section
/// asking for less is clamped up to this (with a note) so a preview can
/// never degenerate into a single unreadable line (issue #678 AC11).
const spillsMinPreviewChars = 200;

/// The `spills:` config section (issue #678).
///
/// Tolerant parse: unknown keys and mistyped values produce [notes] and
/// defaults, never a boot failure — a typo must not kill a session.
final class SpillsConfig {
  /// Creates a configuration; see each field for its default.
  const SpillsConfig({
    this.enabled = true,
    this.threshold = 8192,
    this.headChars = 2000,
    this.tailChars = 2000,
    this.notes = const [],
  });

  /// Master switch: `false` = the hook is never attached, the session is
  /// byte-identical legacy (issue #678 AC1).
  final bool enabled;

  /// Tool results whose text length (UTF-16 code units) exceeds this many
  /// characters spill. `0` = disabled (byte-identical legacy, AC1).
  final int threshold;

  /// Bounded head of the body in the preview (chars).
  final int headChars;

  /// Bounded tail of the body in the preview (chars).
  final int tailChars;

  /// Tolerant-parse notes (unknown keys, clamped values) surfaced at boot.
  final List<String> notes;

  /// Whether spilling can ever fire: the kill-switch and the zero
  /// threshold both mean legacy behavior.
  bool get isActive => enabled && threshold > 0;

  /// Parses the `spills:` yaml section. Tolerant (issue #678 AC11):
  /// booleans/numbers are accepted, mistyped scalars fall back to the
  /// default with a note, unknown keys are noted and ignored, and a
  /// preview bound below [spillsMinPreviewChars] is clamped with a note.
  /// Thresholds below zero clamp to 0 (disabled). Never throws.
  factory SpillsConfig.fromYaml(Object? node) {
    if (node is! Map) return const SpillsConfig();
    final notes = <String>[];
    bool enabled = true;
    var threshold = 8192;
    var headChars = 2000;
    var tailChars = 2000;
    node.forEach((key, value) {
      switch ('$key') {
        case 'enabled':
          if (value is bool) {
            enabled = value;
          } else {
            notes.add('spills.enabled: not a boolean, default applied');
          }
        case 'threshold':
          threshold = _intWithNote(value, 8192, 'spills.threshold', notes);
        case 'headChars':
          headChars = _intWithNote(value, 2000, 'spills.headChars', notes);
        case 'tailChars':
          tailChars = _intWithNote(value, 2000, 'spills.tailChars', notes);
        default:
          notes.add('spills.$key: unknown key (ignored)');
      }
    });
    final (clampedHead, clampedTail) = _clampPreviewBounds(
      headChars,
      tailChars,
      notes,
    );
    if (threshold < 0) {
      notes.add('spills.threshold: negative, clamped to 0 (disabled)');
      threshold = 0;
    }
    return SpillsConfig(
      enabled: enabled,
      threshold: threshold,
      headChars: clampedHead,
      tailChars: clampedTail,
      notes: List.unmodifiable(notes),
    );
  }

  /// AC11: a preview bound below the minimum is clamped (with a note).
  static (int, int) _clampPreviewBounds(
    int headChars,
    int tailChars,
    List<String> notes,
  ) {
    var head = headChars;
    var tail = tailChars;
    if (head < spillsMinPreviewChars) {
      notes.add(
        'spills.headChars: $head below minimum '
        '$spillsMinPreviewChars, clamped',
      );
      head = spillsMinPreviewChars;
    }
    if (tail < spillsMinPreviewChars) {
      notes.add(
        'spills.tailChars: $tail below minimum '
        '$spillsMinPreviewChars, clamped',
      );
      tail = spillsMinPreviewChars;
    }
    return (head, tail);
  }

  static int _intWithNote(
    Object? value,
    int fallback,
    String name,
    List<String> notes,
  ) {
    if (value is int) return value;
    if (value is num) return value.round();
    notes.add('$name: not a number, default applied');
    return fallback;
  }
}

/// True when [text] spills: longer than the threshold and not
/// empty/whitespace (issue #678 AC1 boundary both sides, AC2 empty
/// never spills). Pure function.
bool shouldSpill(String text, SpillsConfig config) {
  // Kill-switch / zero threshold = legacy: nothing ever spills (AC1).
  if (!config.isActive) return false;
  // Empty / whitespace-only results never spill (AC2).
  if (text.trim().isEmpty) return false;
  return text.length > config.threshold;
}

/// Builds the symmetric preview for [body] — exactly what the session
/// stores and the model sees (issue #678 Decision). Pinned sectioning
/// (blank-line separated): header lines / head / omitted marker /
/// tail + read hint:
///
/// ```
/// [spilled: <totalChars> chars, <totalLines> lines (threshold <T> chars)]
/// [spill file: <spillPath>]
///
/// <head — at most headChars, codepoint-safe cut>
///
/// [... <omitted> chars omitted ...]
///
/// <tail — at most tailChars, codepoint-safe cut>
/// [read the spill file above for the full output]
/// ```
///
/// Char-bounded (never line-counted — a single giant line stays bounded,
/// AC3), UTF-16 surrogate-pair-safe (AC4), and the omitted marker
/// (`[... N chars omitted ...]`) carries the TRUE omitted size (AC10).
/// Pure function.
String buildPreview(
  String body, {
  required String spillPath,
  required SpillsConfig config,
}) {
  final head = _headExcerpt(body, config.headChars);
  final tail = _tailExcerpt(body, config.tailChars);
  final omitted = body.length - head.length - tail.length;
  final lines = '\n'.allMatches(body).length + 1;
  return '[spilled: ${body.length} chars, $lines lines '
      '(threshold ${config.threshold} chars)]\n'
      '[spill file: $spillPath]\n'
      '\n'
      '$head\n'
      '\n'
      '[... $omitted chars omitted ...]\n'
      '\n'
      '$tail\n'
      '$spillReadHint';
}

/// The first at most [maxChars] code units of [body], cut on a UTF-16
/// codepoint boundary (a cut never separates a surrogate pair — AC4).
String _headExcerpt(String body, int maxChars) {
  var end = maxChars < body.length ? maxChars : body.length;
  if (end > 0 && end < body.length) {
    final unit = body.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end--;
  }
  return body.substring(0, end);
}

/// The last at most [maxChars] code units of [body], cut on a UTF-16
/// codepoint boundary (AC4).
String _tailExcerpt(String body, int maxChars) {
  var start = body.length - maxChars;
  if (start <= 0) return body;
  final unit = body.codeUnitAt(start);
  if (unit >= 0xDC00 && unit <= 0xDFFF) start++;
  return body.substring(start);
}

/// Writes the full redacted body to `.fah/spills/<sessionId>/<n>.txt`,
/// unique per-session counter names (AC7). Returns the relative spill
/// path, or null when the write failed (AC6 fallback) or no session id is
/// known yet.
final class SpillStore {
  /// Creates a store over [env]; [sessionId] is resolved lazily per write
  /// (the hook attaches before the session exists).
  SpillStore({required ExecutionEnv env, required String? Function() sessionId})
    : _env = env,
      _sessionId = sessionId;

  final ExecutionEnv _env;
  final String? Function() _sessionId;
  String? _counterSession;
  int _counter = 0;

  /// Writes [body] as raw UTF-8 bytes (nothing is re-cut or sanitized on
  /// disk — the body arriving here is already redacted, AC4/AC5) and
  /// returns the path written. Null on any write failure (the caller
  /// falls back inline, AC6). Counter resets when the session changes.
  Future<String?> write(String body) async {
    final sid = _sessionId();
    if (_counterSession != sid) {
      _counterSession = sid;
      _counter = 0;
    }
    // Synchronous increment: no await between read and write, so parallel
    // hook invocations (one tool batch) get unique names (AC7).
    _counter++;
    final path = '.fah/spills/${sid ?? 'sessionless'}/$_counter.txt';
    final written = await _env.writeBinaryFile(path, utf8.encode(body));
    if (written.isErr) return null;
    return path;
  }
}

/// The named inline-fallback marker appended when a spill write fails
/// (issue #678 AC6): the output is never lost and never a silent crash.
String spillFailureMarker(String reason) =>
    '[spill failed: $reason — full output kept inline]';

/// The preview trailer naming what to do with the spill file.
const spillReadHint = '[read the spill file above for the full output]';

/// Replaces every text block in [content] with ONE text block carrying
/// [text] at the first text position; non-text blocks (images) keep their
/// places.
List<ContentBlock> _withSingleText(List<ContentBlock> content, String text) {
  final result = <ContentBlock>[];
  var replaced = false;
  for (final block in content) {
    if (block is TextContent) {
      if (!replaced) {
        result.add(TextContent(text: text));
        replaced = true;
      }
    } else {
      result.add(block);
    }
  }
  if (!replaced) result.add(TextContent(text: text));
  return result;
}

/// Flattens the text blocks of [content] into one spill-candidate body.
String _textContentOf(List<ContentBlock> content) =>
    content.whereType<TextContent>().map((block) => block.text).join('\n');

/// Composes the spill hook onto [agent], preserving hooks already
/// registered (the redactor runs FIRST — spill sees redacted content,
/// issue #678 AC5; secrets never touch disk raw). Oversized results are
/// written to the store and replaced by the symmetric preview; a failed
/// write keeps the full body inline with [spillFailureMarker]. Content
/// the redactor or an earlier hook overrode stays overridden.
void attachSpillHooks(
  Agent agent, {
  required ExecutionEnv env,
  required String? Function() sessionId,
  required SpillsConfig config,
}) {
  final store = SpillStore(env: env, sessionId: sessionId);
  final existingAfter = agent.afterToolCall;
  agent.afterToolCall = (context, cancelToken) async {
    // Existing hooks run first: the redactor has already masked the
    // content we inspect and spill (AC5 — no raw secret touches disk).
    final prior = existingAfter == null
        ? null
        : await existingAfter(context, cancelToken);
    // A read of a spill path is never re-bounded (issue #678: reading
    // the details is the whole point) — re-spilling it would recurse
    // the indirection forever.
    if (context.toolCall.name == 'read' &&
        '${context.toolCall.arguments['path'] ?? ''}'.contains(
          '.fah/spills/',
        )) {
      return prior;
    }
    final content = prior?.content ?? context.result.content;
    final body = _textContentOf(content);
    if (!shouldSpill(body, config)) return prior;
    final spillPath = await store.write(body);
    final List<ContentBlock> newContent;
    if (spillPath == null) {
      // AC6: the write failed — keep the full output inline with a named
      // marker. Output is never lost, never a crash.
      newContent = _withSingleText(
        content,
        '$body\n${spillFailureMarker('could not write spill file')}',
      );
    } else {
      // Symmetric preview: the session and the model see exactly this.
      newContent = _withSingleText(
        content,
        buildPreview(body, spillPath: spillPath, config: config),
      );
    }
    return AfterToolCallResult(
      content: newContent,
      isError: prior?.isError,
      terminate: prior?.terminate,
    );
  };
}
