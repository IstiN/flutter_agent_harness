/// The usage.json persistence half (gh-1241): atomic tmp+rename writes via
/// [ExecutionEnv] (pure-Dart — lib/ must compile for web), stale/corrupt
/// detection against the chain fingerprint (E3), and the I4 byte-scan gate
/// on every write.
///
/// Concurrent resume writers (E2): both processes append their own
/// segment markers to the chain (the session layer owns that fork) and the
/// fold reflects the chain head — on the FILE, last writer wins, so each
/// writer uses a unique tmp name ([tmpSuffix], the host's process id) and
/// the rename is atomic; a torn tmp file is never read.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import 'usage_hygiene.dart';
import 'usage_ledger.dart';

/// Writes and validates `usage.json` artifacts.
final class UsageLedgerWriter {
  /// Creates a [UsageLedgerWriter] over [env]'s filesystem.
  UsageLedgerWriter(this.env);

  /// The filesystem abstraction (never `dart:io` — hosts vary).
  final ExecutionEnv env;

  /// The artifact file name inside a session's usage directory.
  static const artifactFileName = 'usage.json';

  /// Resolves the per-session usage directory: `<sessionsRoot>/<sessionId>`
  /// (gh-1241 surface 1 — the sessions root IS the `.fah/sessions` tree;
  /// session ids are uuidv7 and never collide with the `--cwd-slug--`
  /// workspace directories).
  static String usageDirFor({required String sessionsRoot, required String sessionId}) =>
      '$sessionsRoot/$sessionId';

  /// Writes [ledger] to `<dir>/usage.json` atomically: full bytes to a
  /// unique tmp file, then rename over the target. A crash mid-write
  /// leaves at most a tmp file — the artifact is never partial (E3).
  ///
  /// The serialized artifact passes the I4 byte-scan before touching disk;
  /// a violation throws [UsageHygieneException] and NOTHING is written.
  Future<void> write(
    String dir,
    UsageLedger ledger, {
    String? tmpSuffix,
    Iterable<String> forbiddenSecrets = const [],
    Iterable<String> forbiddenContent = const [],
  }) async {
    // jsonEncode on the schema-ordered map is byte-deterministic (I6):
    // same ledger in, same bytes out.
    final artifact = '${jsonEncode(ledger.toJson())}\n';
    assertUsageArtifactHygiene(
      artifact,
      forbiddenSecrets: forbiddenSecrets,
      forbiddenContent: forbiddenContent,
    );
    final target = '$dir/$artifactFileName';
    final tmp = '$dir/.$artifactFileName.tmp${tmpSuffix == null ? '' : '.$tmpSuffix'}';
    final created = await env.createDir(dir, recursive: true);
    if (created.isErr) {
      throw StateError('usage ledger: cannot create $dir (${created.errorOrNull})');
    }
    final written = await env.writeFile(tmp, artifact);
    if (written.isErr) {
      throw StateError('usage ledger: cannot write $tmp (${written.errorOrNull})');
    }
    // Atomic publish when the host filesystem can rename (E3: a reader
    // never sees a partial artifact); stores without rename (pure web)
    // degrade to write-then-remove — documented, never a crash.
    if (env case final RenamableFileSystem renamable) {
      final renamed = await renamable.renamePath(tmp, target);
      if (renamed.isErr) {
        // Best-effort tmp cleanup; the rename failure is the real error.
        await env.remove(tmp);
        throw StateError(
          'usage ledger: cannot rename to $target (${renamed.errorOrNull})',
        );
      }
    } else {
      final published = await env.writeFile(target, artifact);
      if (published.isErr) {
        await env.remove(tmp);
        throw StateError(
          'usage ledger: cannot write $target (${published.errorOrNull})',
        );
      }
      await env.remove(tmp);
    }
  }

  /// Reads the artifact at `<dir>/usage.json` and returns it when it is
  /// parseable AND its chain fingerprint matches [expectedRecords]/
  /// [expectedHash] (a fresh scan's numbers). Returns `null` for a missing
  /// file, a parse failure, or a fingerprint mismatch — the caller then
  /// REBUILDS from the chain instead of merging into garbage (E3).
  Future<UsageLedger?> readIfValid(
    String dir, {
    required int expectedRecords,
    required String expectedHash,
  }) async {
    final path = '$dir/$artifactFileName';
    final read = await env.readTextFile(path);
    if (read.isErr) return null;
    final Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(read.valueOrNull!);
      if (parsed is! Map) return null;
      decoded = parsed.cast<String, dynamic>();
    } on Object {
      return null;
    }
    final ledger = UsageLedger.fromJson(decoded);
    if (ledger.chainRecords != expectedRecords) return null;
    if (ledger.chainHash != expectedHash) return null;
    if (ledger.sessionId.isEmpty) return null;
    return ledger;
  }
}
