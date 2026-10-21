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
///
/// The same library also hosts the USER-message intake spill (issue #1760):
/// [UserMessageSpillGuard] bounds oversized user messages the same way —
/// spill file `.fah/spills/<sessionId>/user-<n>.md`, redaction before the
/// write, bounded head+tail preview plus a read-in-parts instruction riding
/// the replacement USER message — from one choke point hosts install on
/// `Agent.userMessageGuard`, so every intake (headless, TUI, steering,
/// follow-up, inbox) inherits it.
// ignore_for_file: prefer_initializing_formals
library;

import 'dart:convert';

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../compaction/token_estimation.dart' show estimateStringTokens;
import '../context.dart';
import '../env/execution_env.dart';
import '../prompts/prompts.g.dart';
import '../types.dart';

/// The smallest preview excerpt bound accepted from config. A section
/// asking for less is clamped up to this (with a note) so a preview can
/// never degenerate into a single unreadable line (issue #678 AC11).
const spillsMinPreviewChars = 200;

/// Default absolute byte floor for the user-message path (issue #1760):
/// a user message never spills below this many UTF-8 bytes, whatever the
/// window math says.
const defaultUserSpillThresholdBytes = 16384;

/// Default fraction of the live window budget (effective context window
/// minus the compaction reserve) ONE user message's token estimate may
/// carry before it spills (issue #1760).
const defaultUserSpillWindowFraction = 0.5;

/// The env var a bench/unattended run sets to enable/tune the tool-output
/// cap for ONE run without any config file (gh-1604 item 4): a positive
/// integer is the spill threshold in chars; `0` explicitly disables.
/// Unset or junk leaves the configured section untouched.
///
/// The threshold gates WHEN a result spills; the model-visible preview
/// stays bounded by the head+tail excerpt bounds (defaults:
/// 2000 + 2000). Thresholds below that floor change when spilling
/// fires, not the preview's worst-case size — a spilled body that fits
/// the bounds renders in full.
const spillThresholdEnvVar = 'FAH_SPILL_THRESHOLD';

/// The env knob for the user-message path (issue #1760), same semantics as
/// [spillThresholdEnvVar] but in BYTES: a positive integer is the absolute
/// floor under which a user message never spills; `0` disables the user
/// path for the run; unset or junk leaves the configured section untouched.
const userSpillThresholdEnvVar = 'FAH_USER_SPILL_THRESHOLD';

/// Resolves the run's spills config from the yaml [section] (null when
/// the config files carry no `spills:`) plus the [env] knob
/// ([spillThresholdEnvVar]). Pure:
///
/// - section absent + env unset → null — the hook is never attached, the
///   byte-identical legacy shape (issue #678 AC1);
/// - env set to a positive int → enabled with THAT threshold (env wins
///   over the configured threshold; preview bounds stay the defaults).
///   The section's [SpillsConfig.notes] survive the composition — the
///   tolerant-parse diagnostics a bench run debugging its config needs;
/// - env `0` → explicitly disabled for this run;
/// - env junk → ignored (the section applies untouched; junk never
///   breaks a boot).
SpillsConfig? resolveRunSpillsConfig(
  SpillsConfig? section,
  Map<String, String> env,
) {
  final value = int.tryParse(env[spillThresholdEnvVar]?.trim() ?? '');
  final userValue = int.tryParse(env[userSpillThresholdEnvVar]?.trim() ?? '');
  if (value == null && userValue == null) return section;
  // The section kill-switch beats the env knobs (issue #1760 review): a
  // bench knob tunes/enables within an enabled-or-absent section — it
  // never resurrects a section the user switched off.
  if (section != null && !section.enabled) return section;
  if (value != null && value <= 0) return const SpillsConfig(enabled: false);
  final base = section ?? const SpillsConfig();
  // The USER knob scopes itself to the user path: with no section it must
  // not arm tool-result spilling as a side effect (threshold stays 0 →
  // isActive false, isUserActive per the knob).
  final toolOff = section == null && value == null;
  return SpillsConfig(
    enabled: true,
    threshold: toolOff ? 0 : (value ?? base.threshold),
    headChars: base.headChars,
    tailChars: base.tailChars,
    userThreshold: userValue ?? base.userThreshold,
    userFraction: base.userFraction,
    notes: base.notes,
  );
}

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
    this.userThreshold = defaultUserSpillThresholdBytes,
    this.userFraction = defaultUserSpillWindowFraction,
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

  /// Absolute byte floor for the user-message path (issue #1760): a user
  /// message never spills below this many UTF-8 bytes, whatever the window
  /// math says. `0` = the user path is disabled. Tuned by
  /// [userSpillThresholdEnvVar] for one run.
  final int userThreshold;

  /// The fraction of the live window budget (effective context window minus
  /// the compaction reserve) ONE user message's token estimate may carry
  /// before it spills (issue #1760) — the relative half of the threshold.
  final double userFraction;

  /// Tolerant-parse notes (unknown keys, clamped values) surfaced at boot.
  final List<String> notes;

  /// Whether spilling can ever fire: the kill-switch and the zero
  /// threshold both mean legacy behavior.
  bool get isActive => enabled && threshold > 0;

  /// Whether USER-message spilling can fire (issue #1760): the section
  /// kill-switch plus the user path's own zero floor. Orthogonal to
  /// [isActive] — `threshold: 0` silences tool results only.
  bool get isUserActive => enabled && userThreshold > 0;

  /// The `spills:` yaml section, only the non-default values — the file
  /// stays minimal (defaults are never written). Empty at the defaults,
  /// so [CliConfig.toYaml] embeds it only when explicitly configured
  /// (gh-1572: the section used to be unrenderable and silently dropped
  /// by every save).
  String toYaml() {
    if (enabled &&
        threshold == 8192 &&
        headChars == 2000 &&
        tailChars == 2000 &&
        userThreshold == defaultUserSpillThresholdBytes &&
        userFraction == defaultUserSpillWindowFraction) {
      return '';
    }
    final buffer = StringBuffer('spills:\n');
    if (!enabled) buffer.write('  enabled: false\n');
    if (threshold != 8192) buffer.write('  threshold: $threshold\n');
    if (headChars != 2000) buffer.write('  headChars: $headChars\n');
    if (tailChars != 2000) buffer.write('  tailChars: $tailChars\n');
    if (userThreshold != defaultUserSpillThresholdBytes) {
      buffer.write('  userThreshold: $userThreshold\n');
    }
    if (userFraction != defaultUserSpillWindowFraction) {
      buffer.write('  userFraction: $userFraction\n');
    }
    return buffer.toString();
  }

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
    var userThreshold = defaultUserSpillThresholdBytes;
    var userFraction = defaultUserSpillWindowFraction;
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
        case 'userThreshold':
          userThreshold = _intWithNote(
            value,
            defaultUserSpillThresholdBytes,
            'spills.userThreshold',
            notes,
          );
        case 'userFraction':
          if (value is num) {
            userFraction = value.toDouble();
          } else {
            notes.add('spills.userFraction: not a number, default applied');
          }
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
    if (userThreshold < 0) {
      notes.add('spills.userThreshold: negative, clamped to 0 (disabled)');
      userThreshold = 0;
    }
    if (userFraction < 0) {
      notes.add('spills.userFraction: negative, clamped to 0');
      userFraction = 0;
    }
    return SpillsConfig(
      enabled: enabled,
      threshold: threshold,
      headChars: clampedHead,
      tailChars: clampedTail,
      userThreshold: userThreshold,
      userFraction: userFraction,
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

/// True when a user message's TEXT spills (issue #1760): the message alone
/// threatens the live window budget — its token estimate exceeds
/// [SpillsConfig.userFraction] of [budgetTokens] (the effective context
/// window minus the compaction reserve) — AND the text is past the absolute
/// [SpillsConfig.userThreshold] byte floor. Pure function.
bool shouldSpillUserMessage(
  String text,
  SpillsConfig config,
  int budgetTokens,
) {
  if (!config.enabled) {
    return false; // the section kill-switch covers both paths
  }
  if (config.userThreshold <= 0) return false; // the user path's own switch
  if (text.trim().isEmpty) return false;
  if (utf8.encode(text).length <= config.userThreshold) return false;
  return estimateStringTokens(text) >
      (config.userFraction * budgetTokens).floor();
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
  String? thresholdNote,
}) {
  final note = thresholdNote ?? 'threshold ${config.threshold} chars';
  // A body the preview bounds already cover renders ONCE — the naive
  // head+tail concat would duplicate it with a negative omitted count
  // (gh-1604: a bench threshold below head+tail bounds must not double
  // the body into the "bounded" preview).
  if (body.length <= config.headChars + config.tailChars) {
    final lines = '\n'.allMatches(body).length + 1;
    return '[spilled: ${body.length} chars, $lines lines ($note)]\n'
        '[spill file: $spillPath]\n'
        '\n'
        '$body\n'
        '$spillReadHint';
  }
  final head = _headExcerpt(body, config.headChars);
  final tail = _tailExcerpt(body, config.tailChars);
  final omitted = body.length - head.length - tail.length;
  final lines = '\n'.allMatches(body).length + 1;
  return '[spilled: ${body.length} chars, $lines lines ($note)]\n'
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
  /// (the hook attaches before the session exists). [fileName] names the
  /// file per counter — tool results use the `<n>.txt` default, user
  /// messages the `user-<n>.md` layout (issue #1760).
  SpillStore({
    required ExecutionEnv env,
    required String? Function() sessionId,
    String Function(int counter) fileName = _defaultSpillFileName,
  }) : _env = env,
       _sessionId = sessionId,
       _fileName = fileName;

  static String _defaultSpillFileName(int counter) => '$counter.txt';

  final ExecutionEnv _env;
  final String? Function() _sessionId;
  final String Function(int counter) _fileName;
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
    final path = '.fah/spills/${sid ?? 'sessionless'}/${_fileName(_counter)}';
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

/// Builds the bounded replacement riding a spilled user message
/// (issue #1760): the read-in-parts instruction (the `prompts/spill/`
/// copy) naming the path and byte size, followed by the symmetric preview
/// (issue #678 shape) with a user-flavored threshold note. Pure function.
String buildUserSpillReplacement(
  String body, {
  required String spillPath,
  required int budgetTokens,
  required SpillsConfig config,
}) {
  final bytes = utf8.encode(body).length;
  final instruction = userSpillInstructionPrompt
      .replaceAll('{{path}}', spillPath)
      .replaceAll('{{bytes}}', '$bytes');
  return '$instruction\n\n'
      '${buildPreview(body, spillPath: spillPath, config: config, thresholdNote: 'token estimate ${estimateStringTokens(body)}, '
          'window budget $budgetTokens tokens')}';
}

/// The oversized user-message intake guard (issue #1760) — the ONE choke
/// point every host installs on [Agent.userMessageGuard]: every incoming
/// user message (headless `-p`/positional prompt, TUI first message or
/// mid-session input, steering / follow-up queue drain, external inbox)
/// passes through it. An oversized message's text is redacted, written
/// verbatim to `.fah/spills/<sessionId>/user-<n>.md` (the #678 layout) and
/// replaced by a bounded head+tail preview plus the read-in-parts
/// instruction riding the replacement USER message; images stay inline.
/// A refused (or otherwise failed) write degrades to today's inline
/// behavior — the message passes through unchanged, never a crash (AC7).
final class UserMessageSpillGuard {
  /// Creates a guard. [budgetTokens] resolves the LIVE window budget per
  /// message (effective context window minus the compaction reserve — the
  /// same numbers the compaction driver and the ctx meter use); [redact]
  /// runs BEFORE the spill write so raw secrets never touch disk (AC6).
  UserMessageSpillGuard({
    required ExecutionEnv env,
    required this.config,
    required this.budgetTokens,
    required String? Function() sessionId,
    String Function(String text)? redact,
  }) : _store = SpillStore(
         env: env,
         sessionId: sessionId,
         fileName: _userSpillFileName,
       ),
       _redact = redact;

  static String _userSpillFileName(int counter) => 'user-$counter.md';

  final SpillsConfig config;
  final int Function() budgetTokens;
  final String Function(String text)? _redact;
  final SpillStore _store;

  /// Guards one incoming user message. Returns [message] unchanged when
  /// the text is below threshold or the spill write failed. Never throws.
  Future<UserMessage> guard(UserMessage message) async {
    try {
      return await _guard(message);
    } on Object {
      return message; // AC7: a broken guard must never kill an intake.
    }
  }

  Future<UserMessage> _guard(UserMessage message) async {
    final content = message.content;
    final raw = content is String
        ? content
        : _textContentOf(content as List<ContentBlock>);
    // Idempotence (issue #1760 review): an already-spilled replacement —
    // a steered message that pre-spilled at accept, then drains through
    // the seam again — passes through unchanged. Re-spilling the bounded
    // preview would fork the FIFO's object identity and multiply spill
    // files; the pinned preview header only occurs in spill artifacts.
    if (raw.contains('[spilled: ') && raw.contains('[spill file: ')) {
      return message;
    }
    final budget = budgetTokens();
    if (!shouldSpillUserMessage(raw, config, budget)) return message;
    // Redaction BEFORE the write (AC6) — and the replacement preview is
    // built from the same redacted body, so file and message agree.
    final body = _redact == null ? raw : _redact(raw);
    final spillPath = await _store.write(body);
    if (spillPath == null) return message; // write refused → inline legacy
    final replacement = buildUserSpillReplacement(
      body,
      spillPath: spillPath,
      budgetTokens: budget,
      config: config,
    );
    return UserMessage(
      content: content is String
          ? replacement
          : _withSingleText(content as List<ContentBlock>, replacement),
      timestamp: message.timestamp,
    );
  }
}
