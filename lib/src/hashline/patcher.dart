/// High-level patch orchestrator, ported from oh-my-pi
/// `packages/hashline/src/patcher.ts`. Reads each section's target file via
/// the ambient [ExecutionEnv], strips BOM and normalizes line endings,
/// validates the section snapshot tag, applies the edits in memory, and
/// writes the result back through the same env.
///
/// Two layers:
///
/// - [HashlinePatcher.apply] — high-level, all-or-nothing. Preflights every
///   section in memory before any write hits the filesystem, then commits in
///   order.
/// - [HashlinePatcher.prepare] / [HashlinePatcher.commit] — granular
///   primitives for callers that need per-section control.
///
/// Divergences from omp: no tree-sitter block resolution, no `REM`/`MV`
/// file ops, no diff-based stale-anchor auto-remap (`recovery.ts`) — a stale
/// anchored edit rejects with a [HashlineMismatchError] that names the
/// drifted lines, and the model re-reads. No LSP/write-guard hooks either.
library;

import '../env/execution_env.dart';
import 'apply.dart';
import 'format.dart';
import 'input.dart';
import 'messages.dart';
import 'mismatch.dart';
import 'normalize.dart';
import 'snapshots.dart';
import 'types.dart';

/// Upper bound on the number of unseen anchor lines whose actual file
/// content is inlined into a rejection error (omp's `SEEN_LINE_REVEAL_CAP`).
const seenLineRevealCap = 40;

/// Per-revealed-line character cap, so a revealed anchor line can never dump
/// a minified megabyte-wide line into the tool error and model context
/// (omp's `SEEN_LINE_REVEAL_MAX_COLUMNS`).
const seenLineRevealMaxColumns = 512;

/// Per-section outcome of [HashlinePatcher.commit].
enum HashlineSectionOp {
  /// The file content changed and was written.
  update,

  /// The apply produced no change; nothing was written.
  noop,
}

/// Per-section result returned by [HashlinePatcher.apply] /
/// [HashlinePatcher.commit].
final class HashlineSectionResult {
  /// Creates a section result.
  const HashlineSectionResult({
    required this.path,
    required this.canonicalPath,
    required this.op,
    required this.before,
    required this.after,
    required this.persisted,
    required this.fileHash,
    required this.header,
    required this.warnings,
    this.firstChangedLine,
  });

  /// Section path (as authored).
  final String path;

  /// Env-canonical key for this section (absolute path).
  final String canonicalPath;

  /// Whether the file was written.
  final HashlineSectionOp op;

  /// Pre-edit text (LF-normalized, BOM-stripped).
  final String before;

  /// Post-edit text (LF-normalized, BOM-stripped). For
  /// [HashlineSectionOp.noop] equals [before].
  final String after;

  /// Same text as [after] but with the original BOM and line ending
  /// restored — what was (or would be) written.
  final String persisted;

  /// 4-hex content-hash tag for [after]. Use to anchor follow-up edits.
  final String fileHash;

  /// Hashline section header (`[path#tag]`) of the post-edit content.
  final String header;

  /// 1-indexed first changed line in [after], or `null` for noops.
  final int? firstChangedLine;

  /// Warnings collected by the parser and patcher.
  final List<String> warnings;
}

/// Aggregate result of [HashlinePatcher.apply].
final class HashlinePatcherApplyResult {
  /// Creates a result with one entry per section in patch order.
  const HashlinePatcherApplyResult({required this.sections});

  /// Per-section results in the original patch order.
  final List<HashlineSectionResult> sections;
}

/// Opaque token returned by [HashlinePatcher.prepare]. Carries the section,
/// the raw file content read off the filesystem, and the in-memory apply
/// result. [HashlinePatcher.commit] just writes it.
final class HashlinePreparedSection {
  HashlinePreparedSection._({
    required this.section,
    required this.canonicalPath,
    required this.rawContent,
    required this.bom,
    required this.lineEnding,
    required this.normalized,
    required this.applyResult,
    required this.parseWarnings,
  });

  /// The (possibly path-recovered) section.
  final HashlinePatchSection section;

  /// Env-canonical path key.
  final String canonicalPath;

  /// Raw file content as read.
  final String rawContent;

  /// Leading BOM (`''` or `'\uFEFF'`).
  final String bom;

  /// Detected line-ending style.
  final LineEnding lineEnding;

  /// Pre-edit text (LF-normalized, BOM-stripped).
  final String normalized;

  /// The in-memory apply result.
  final HashlineApplyResult applyResult;

  /// Warnings collected while parsing the section body.
  final List<String> parseWarnings;

  /// True when the apply produced no change.
  bool get isNoop => applyResult.text == normalized;
}

final class _ReadOutcome {
  const _ReadOutcome({required this.exists, required this.rawContent});
  final bool exists;
  final String rawContent;
}

/// High-level patcher. Wires an [ExecutionEnv] and a [HashlineSnapshotStore]
/// together with the parsing + applying core. Construct once per session;
/// reuse across patches.
final class HashlinePatcher {
  /// Creates a patcher over [env] with the session [snapshots] store.
  ///
  /// [enforceSeenLines] (default `true`) rejects anchored edits on lines the
  /// read that minted the tag never displayed; when `false`, tags validate
  /// on content hash alone and any anchor into the tagged content applies.
  const HashlinePatcher({
    required this.env,
    required this.snapshots,
    this.enforceSeenLines = true,
  });

  /// Filesystem/process environment used for all reads and writes.
  final ExecutionEnv env;

  /// Snapshot store that minted and resolves hashline section tags.
  final HashlineSnapshotStore snapshots;

  /// Whether the seen-line guard is enforced (see constructor).
  final bool enforceSeenLines;

  /// Applies every section in [patch]. [prepare] runs the full apply for
  /// each section in memory before any write hits the filesystem, so a
  /// multi-section batch is naturally all-or-nothing. Returns one
  /// [HashlineSectionResult] per section in the original patch order.
  Future<HashlinePatcherApplyResult> apply(HashlinePatch patch) async {
    // Single-section fast path.
    if (patch.sections.length == 1) {
      final prepared = await prepare(patch.sections[0]);
      return HashlinePatcherApplyResult(sections: [await commit(prepared)]);
    }

    // Prepare every section first so any failure (stale hash, missing
    // file, parse error, in-memory no-op) surfaces before any write.
    final prepared = <HashlinePreparedSection>[];
    for (final section in patch.sections) {
      prepared.add(await prepare(section));
    }
    _assertUniqueCanonicalPaths(prepared);
    for (final entry in prepared) {
      if (entry.isNoop) {
        throw StateError(noChangeDiagnostic(entry.section.path));
      }
    }

    final results = <HashlineSectionResult>[];
    for (var index = 0; index < prepared.length; index++) {
      try {
        results.add(await commit(prepared[index]));
      } on Object catch (error) {
        // A mid-batch write failure leaves earlier sections on disk with no
        // rollback; report exactly which sections landed so the caller can
        // re-issue only the missing ones instead of double-applying.
        final written = [
          for (var i = 0; i < index; i++) prepared[i].section.path,
        ];
        final notWritten = [
          for (var i = index + 1; i < prepared.length; i++)
            prepared[i].section.path,
        ];
        final buffer = StringBuffer(
          'Failed to write ${prepared[index].section.path}: $error',
        );
        if (written.isNotEmpty) {
          buffer.write(' Sections already written: ${written.join(', ')}.');
        }
        if (notWritten.isNotEmpty) {
          buffer.write(' Sections not written: ${notWritten.join(', ')}.');
        }
        throw StateError(buffer.toString());
      }
    }
    return HashlinePatcherApplyResult(sections: results);
  }

  void _assertUniqueCanonicalPaths(List<HashlinePreparedSection> prepared) {
    final seen = <String, String>{};
    for (final entry in prepared) {
      final previous = seen[entry.canonicalPath];
      if (previous != null) {
        throw StateError(
          'Multiple hashline sections resolve to the same file ($previous '
          'and ${entry.section.path}). Merge their ops under one header '
          'before applying.',
        );
      }
      seen[entry.canonicalPath] = entry.section.path;
    }
  }

  /// Reads a section's target file, parses the section, validates the
  /// snapshot tag, and applies the edits in memory. Returns a
  /// [HashlinePreparedSection] which can be fed to [commit] to land the
  /// result on the filesystem.
  ///
  /// Throws on parse error, missing file, or tag mismatch
  /// ([HashlineMismatchError]).
  Future<HashlinePreparedSection> prepare(HashlinePatchSection section) async {
    final parsed = section.parse();
    final parseWarnings = [...parsed.warnings];
    final fileHash = section.fileHash;
    if (fileHash == null) {
      throw StateError(missingSnapshotTagMessage(section.path));
    }

    var target = section;
    var canonicalPath = await _canonicalPath(target.path);
    var read = await _tryRead(target.path);

    // Path recovery: the authored path doesn't exist on disk, but its
    // filename + snapshot tag may name a file the model read this session
    // (it supplied a bare filename, or the wrong directory). Rebind to that
    // file so the edit lands where the tag points, and warn.
    if (!read.exists) {
      final recoveredPath = _recoverSectionPathFromTag(target, canonicalPath);
      if (recoveredPath != null) {
        parseWarnings.add(
          pathRecoveredFromTagMessage(target.path, recoveredPath, fileHash),
        );
        target = target.withPath(recoveredPath);
        canonicalPath = await _canonicalPath(target.path);
        read = await _tryRead(target.path);
      }
    }

    if (!read.exists) {
      throw StateError(
        'File not found: ${target.path}. Use the write tool to create new '
        'files.',
      );
    }

    final stripped = stripBom(read.rawContent);
    // A UTF-8 BOM may be hidden by the env's text decoder (Dart's
    // utf8.decode eats a leading BOM); recover it from the raw bytes so the
    // write-back preserves it (omp #3867).
    final bom = stripped.bom.isNotEmpty
        ? stripped.bom
        : await _readBinaryBom(target.path);
    final lineEnding = detectLineEnding(stripped.text);
    final normalized = normalizeToLF(stripped.text);

    final applyResult = _applyWithGuards(
      section: target,
      canonicalPath: canonicalPath,
      normalized: normalized,
    );

    return HashlinePreparedSection._(
      section: target,
      canonicalPath: canonicalPath,
      rawContent: read.rawContent,
      bom: bom,
      lineEnding: lineEnding,
      normalized: normalized,
      applyResult: applyResult,
      parseWarnings: parseWarnings,
    );
  }

  Future<String> _readBinaryBom(String path) async {
    final read = await env.readBinaryFile(path);
    if (read.isErr) return '';
    final bytes = read.valueOrNull!;
    final hasUtf8Bom =
        bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF;
    return hasUtf8Bom ? '\uFEFF' : '';
  }

  /// Commits a previously [prepare]d section to the filesystem. Restores
  /// line endings and BOM, writes via the env, and records a fresh snapshot
  /// in the store keyed by the env-canonical path.
  Future<HashlineSectionResult> commit(HashlinePreparedSection prepared) async {
    final section = prepared.section;
    final normalized = prepared.normalized;
    final after = prepared.applyResult.text;
    final warnings = [
      ...prepared.parseWarnings,
      ...prepared.applyResult.warnings,
    ];

    if (after == normalized) {
      final hash = snapshots.record(prepared.canonicalPath, normalized);
      return HashlineSectionResult(
        path: section.path,
        canonicalPath: prepared.canonicalPath,
        op: HashlineSectionOp.noop,
        before: normalized,
        after: normalized,
        persisted: prepared.rawContent,
        fileHash: hash,
        header: formatHashlineHeader(section.path, hash),
        warnings: warnings,
      );
    }

    final persisted =
        prepared.bom + restoreLineEndings(after, prepared.lineEnding);
    final written = await env.writeFile(section.path, persisted);
    if (written.isErr) throw StateError('${written.errorOrNull}');
    final fileHash = snapshots.record(prepared.canonicalPath, after);

    return HashlineSectionResult(
      path: section.path,
      canonicalPath: prepared.canonicalPath,
      op: HashlineSectionOp.update,
      before: normalized,
      after: after,
      persisted: persisted,
      fileHash: fileHash,
      header: formatHashlineHeader(section.path, fileHash),
      firstChangedLine: prepared.applyResult.firstChangedLine,
      warnings: warnings,
    );
  }

  Future<String> _canonicalPath(String path) async {
    final result = await env.absolutePath(path);
    return result.valueOrNull ?? path;
  }

  Future<_ReadOutcome> _tryRead(String path) async {
    final read = await env.readTextFile(path);
    if (read.isOk) {
      return _ReadOutcome(exists: true, rawContent: read.valueOrNull!);
    }
    final error = read.errorOrNull!;
    if (error.code == FileErrorCode.notFound) {
      return const _ReadOutcome(exists: false, rawContent: '');
    }
    throw StateError('$error');
  }

  /// Resolves a missing authored path to a file read this session by
  /// matching its filename and snapshot tag. Returns the matching canonical
  /// path, or `null` when no unique filename+tag match exists.
  String? _recoverSectionPathFromTag(
    HashlinePatchSection section,
    String originalCanonicalPath,
  ) {
    final tag = section.fileHash;
    if (tag == null) return null;
    final authoredName = _basename(section.path);
    final candidates = <String>{};
    for (final snapshot in snapshots.findByHash(tag)) {
      if (_basename(snapshot.path) != authoredName) continue;
      if (snapshot.path == originalCanonicalPath) continue;
      candidates.add(snapshot.path);
    }
    if (candidates.length != 1) return null;
    return candidates.first;
  }

  HashlineMismatchError _mismatchError(
    HashlinePatchSection section,
    String canonicalPath,
    String normalized,
    String expected,
  ) {
    final actualFileHash = snapshots.record(canonicalPath, normalized);
    return HashlineMismatchError(
      path: section.path,
      expectedFileHash: expected,
      actualFileHash: actualFileHash,
      fileLines: normalized.split('\n'),
      anchorLines: section.collectAnchorLines(),
      hashRecognized: snapshots.byHash(canonicalPath, expected) != null,
    );
  }

  HashlineApplyResult _applyWithGuards({
    required HashlinePatchSection section,
    required String canonicalPath,
    required String normalized,
  }) {
    final expected = section.fileHash!;
    final edits = section.edits;
    // The 4-hex tag is content-derived: when the live text hashes to it,
    // trust the match and apply directly.
    final liveMatches = computeFileHash(normalized) == expected;
    final matchedSnapshot = liveMatches
        ? snapshots.byContent(canonicalPath, normalized)
        : null;

    // The tag still names the live content: an edit anchored at any line is
    // safe to apply.
    if (liveMatches) {
      // The line numbers in `edits` index the exact content the tag names.
      // Reject any anchor the read never displayed: editing lines the model
      // has not seen is the off-by-memory mistake that mangles files.
      if (enforceSeenLines) {
        _assertSeenLines(section, expected, matchedSnapshot);
      }
      return applyHashlineEdits(normalized, edits);
    }

    // Head/tail-only inserts are position-stable: "start"/"end" cannot move
    // with content drift, so a stale tag is non-fatal. Apply onto the live
    // content and warn instead of hard-failing — unlike an anchored
    // mismatch, which cannot be safely relocated and must reject.
    if (!section.hasAnchorScopedEdit) {
      final result = applyHashlineEdits(normalized, edits);
      return HashlineApplyResult(
        text: result.text,
        firstChangedLine: result.firstChangedLine,
        warnings: [headTailDriftWarning, ...result.warnings],
      );
    }

    // File drifted under anchored edits: reject with the live context so
    // the model re-reads instead of retrying blind. (omp additionally
    // attempts a diff-based anchor remap here; this port deliberately
    // rejects instead — the mismatch message names the drifted lines.)
    throw _mismatchError(section, canonicalPath, normalized, expected);
  }

  /// Rejects an anchored edit that references a line the read which minted
  /// [expected] never displayed. [matchedSnapshot] is the store version
  /// whose text equals the live normalized content — the exact snapshot the
  /// model anchored against. Null means no provenance was recorded, so the
  /// edit applies as before.
  ///
  /// The rejection inlines the actual file content at the unseen anchor
  /// lines so the model can verify what it was about to touch. When the
  /// reveal covers EVERY unseen anchor line in full width, those lines also
  /// merge into the snapshot's seen-line set, so a straight retry with the
  /// same `[path#tag]` header succeeds without a follow-up range read — the
  /// content the model received in the error IS proof it has now seen those
  /// lines (omp's `assertSeenLines`).
  void _assertSeenLines(
    HashlinePatchSection section,
    String expected,
    HashlineSnapshot? matchedSnapshot,
  ) {
    final seen = matchedSnapshot?.seenLines;
    if (seen == null || seen.isEmpty) return;
    final unseen = [
      for (final line in section.collectAnchorLines())
        if (!seen.contains(line)) line,
    ];
    if (unseen.isEmpty) return;
    final sourceLines = matchedSnapshot!.text.split('\n');
    final revealed = <RevealedLine>[];
    final revealCount = unseen.length < seenLineRevealCap
        ? unseen.length
        : seenLineRevealCap;
    var columnTruncated = false;
    for (var i = 0; i < revealCount; i++) {
      final line = unseen[i];
      // Out-of-range anchors are caught by apply with a better message;
      // skip them here so they never join the revealed set.
      if (line < 1 || line > sourceLines.length) continue;
      final source = sourceLines[line - 1];
      if (source.length > seenLineRevealMaxColumns) {
        revealed.add((
          line: line,
          text: '${source.substring(0, seenLineRevealMaxColumns)}…',
        ));
        columnTruncated = true;
      } else {
        revealed.add((line: line, text: source));
      }
    }
    final truncated = unseen.length > revealed.length || columnTruncated;
    // Only merge when the reveal covered every unseen anchor line in full
    // width. A prefix-truncated reveal would let the model split a blind
    // edit into <=cap-line retries and land it without ever running the
    // required range re-read.
    if (!truncated) {
      for (final line in revealed) {
        seen.add(line.line);
      }
    }
    throw StateError(
      unseenLinesMessage(section.path, unseen, expected, (
        lines: revealed,
        truncated: truncated,
      )),
    );
  }
}

String _basename(String path) {
  final normalized = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final index = normalized.lastIndexOf('/');
  return index == -1 ? normalized : normalized.substring(index + 1);
}
