/// Tool-misuse coercion policies (issue #862): pure decisions that turn an
/// unambiguous parameter misuse into a coerced call + a notice, and turn a
/// genuine rejection into a remedy-bearing error.
///
/// The luna incident (2026-09-23, trajectory rev 178): a model filled BOTH
/// edit modes' parameters, was hard-rejected 15 consecutive times, looped,
/// and finally hallucinated success while no edit landed. Every wall it hit
/// was a harness-chosen hard rejection where coercion or education was
/// possible. These policies are the coercion layer: deterministic, pure, and
/// individually tested (positive AND negative per card).
///
/// Policy invariants:
/// - Coercion only fires on UNAMBIGUOUS misuse; genuine ambiguity still
///   rejects, but the error ends with a minimal correct-call example.
/// - Every notice names the ignored parameter and why (the model must learn
///   the correct shape from the outcome alone).
/// - At most one mode ever applies (E1): a contradictory pair never applies
///   both.
library;

import '../hashline/input.dart';

/// The minimal correct-call example appended to edit validation errors
/// (remedy-bearing rejections, card §Architecture).
const editRemedyExample =
    'Example: edit(path: "file.txt", oldText: "exact text", newText: '
    '"replacement") OR edit(patch: "[file.txt#a1b2c3]\\n= 3 5\\n+ new line") '
    '-- send ONE mode, never both.';

/// The minimal correct-call example for read window misuse.
const readRemedyExample =
    'Example: read("file.dart:50-100") for a line window, or '
    'read("file.dart", offset: 50, limit: 50) -- never both.';

/// How [resolveEditMode] decided to run an edit call whose arguments mixed
/// the two edit modes (or carried neither).
sealed class EditModePlan {
  const EditModePlan();

  /// Notice appended to the result naming what was ignored and why; null
  /// when nothing was coerced (the model sent exactly one mode).
  String? get notice => null;
}

/// Run hashline-patch mode. A usable patch wins whenever present (E1);
/// [parsed] is the ONE shared parse — the executor consumes it directly so
/// the gate and the apply can never drift apart again (issue #862 review).
final class EditRunPatch extends EditModePlan {
  const EditRunPatch({required this.patch, required this.parsed, this.notice});

  final String patch;

  /// The patch parsed once by [parsePatch] (with the executor's
  /// `fallbackPath` contract honored).
  final HashlinePatch parsed;

  @override
  final String? notice;
}

/// The outcome of parsing an edit call's patch input — exactly once per
/// call (issue #862 review: the second parse was not guaranteed equivalent
/// to the executor's).
final class PatchParse {
  const PatchParse.usable(HashlinePatch this.patch) : error = null;

  const PatchParse.failed(String this.error) : patch = null;

  /// The parsed patch when usable, null otherwise.
  final HashlinePatch? patch;

  /// The parser's own diagnostic when unusable, null when usable.
  final String? error;

  bool get usable => patch != null;
}

/// Parses [patch] once, honoring the executor's `fallbackPath` contract: a
/// header-less input whose lines are still recognizable hashline ops parses
/// with [fallbackPath] as the section path — exactly what
/// `HashlinePatch.parse(patch, fallbackPath: path)` does at apply time.
PatchParse parsePatch(String? patch, {String? fallbackPath}) {
  if (patch == null || patch.trim().isEmpty) {
    return const PatchParse.failed('no patch argument');
  }
  try {
    final parsed = HashlinePatch.parse(patch, fallbackPath: fallbackPath);
    if (parsed.sections.isEmpty) {
      return const PatchParse.failed('no [path#TAG] section header found');
    }
    return PatchParse.usable(parsed);
  } on Object catch (error) {
    return PatchParse.failed(
      '$error'.replaceFirst(
        RegExp(r'^(Bad state:|HashlineFormatException:)\s*'),
        '',
      ),
    );
  }
}

/// Run exact-match mode because the patch input was not a usable patch
/// while the exact-match triple was complete (AC2).
final class EditRunExactMatch extends EditModePlan {
  const EditRunExactMatch({
    required this.path,
    required this.oldText,
    required this.newText,
    this.notice,
  });

  final String path;
  final String oldText;
  final String newText;

  @override
  final String? notice;
}

/// Neither mode is complete — reject with the remedy example (AC3).
final class EditReject extends EditModePlan {
  const EditReject(this.message);

  final String message;
}

/// Whether an exact-match triple is complete: all three present, oldText
/// non-empty (newText may be empty — that deletes oldText).
bool exactMatchComplete({
  required String? path,
  required String? oldText,
  required String? newText,
}) =>
    path != null &&
    path.isNotEmpty &&
    oldText != null &&
    oldText.isNotEmpty &&
    newText != null;

/// The both-modes notice: names the ignored exact-match payload and the
/// winner, so the model stops re-sending the pair (E4).
String bothModesNotice({required String winner}) =>
    'Note: the call carried BOTH edit modes; the harness applied '
    '$winner and IGNORED the other mode\'s arguments '
    '(oldText/newText or patch). Send exactly one mode per call.';

/// Resolves an edit tool call's mode from its raw arguments (UT-1..3, E1).
///
/// Deterministic policy (card OQ1, patch-first):
/// - A usable patch wins whenever present — the hashline header is
///   self-validating and a stale tag rejects before any write, so a
///   complete patch is the safer of the two modes.
/// - A malformed patch with a complete exact-match triple falls back to
///   exact-match (AC2) instead of rejecting.
/// - Only "neither mode complete" rejects, with the remedy example (AC3).
EditModePlan resolveEditMode({
  required String? path,
  required String? oldText,
  required String? newText,
  required String? patch,
}) {
  final exactComplete = exactMatchComplete(
    path: path,
    oldText: oldText,
    newText: newText,
  );
  // ONE parse, honoring the executor's fallbackPath contract, carried
  // through the plan (issue #862 review).
  final parse = parsePatch(patch, fallbackPath: path);

  if (parse.usable) {
    final mixed = oldText != null || newText != null;
    return EditRunPatch(
      patch: patch!,
      parsed: parse.patch!,
      notice: mixed
          ? bothModesNotice(winner: 'the hashline patch')
          : null,
    );
  }
  if (exactComplete) {
    final patchSent = patch != null && patch.trim().isNotEmpty;
    return EditRunExactMatch(
      path: path!,
      oldText: oldText!,
      newText: newText!,
      notice: patchSent
          ? bothModesNotice(winner: 'the exact-match replace')
          : null,
    );
  }
  if (patch != null && patch.trim().isNotEmpty) {
    // A patch was attempted but is malformed, and exact-match cannot
    // rescue the call: reject with the parser's focused diagnostic plus
    // the remedy (AC3's sibling shape).
    return EditReject(
      'The patch input is not a valid hashline patch '
      '(${parse.error}), and the exact-match arguments are '
      'incomplete. $editRemedyExample',
    );
  }
  return EditReject(
    'Missing arguments: provide either patch (hashline mode) or path + '
    'oldText + newText (exact-match mode). $editRemedyExample',
  );
}

/// Resolves a read tool call's window when a trailing selector and
/// offset/limit arrive together (UT-4, AC4): the selector pins the window,
/// so offset/limit are ignored with a notice instead of hard-rejecting.
///
/// Returns the notice to append to the result, or null when the call was
/// already unambiguous.
String? readWindowCoercionNotice({
  required bool hasSelector,
  required int? offset,
  required int? limit,
}) {
  if (!hasSelector || (offset == null && limit == null)) return null;
  return 'Note: offset/limit cannot be combined with a path selector; '
      'the harness honored the selector and IGNORED '
      '${[
        if (offset != null) 'offset',
        if (limit != null) 'limit',
      ].join(' and ')}. $readRemedyExample';
}
