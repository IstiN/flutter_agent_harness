/// Swaps a freshly downloaded CLI binary into place without ever leaving the
/// install without a runnable executable.
///
/// Windows cannot overwrite a running executable, so a self-update renames the
/// live binary aside and renames the staged one into its place. The original
/// implementation did exactly those two renames with **no verification and no
/// rollback**: a truncated download, an antivirus holding the staged file, or
/// the process dying between them left the install with `fa.exe.old` and no
/// `fa.exe` — after which every shell answers `fa: command not found`, with
/// nothing on disk telling the user that the previous binary is right there
/// (issue #2052).
///
/// The swap now:
///  1. refuses a staging file that is missing or empty — the fingerprint of a
///     failed download/extract — and leaves [target] untouched;
///  2. rolls the parked binary back when the swap-in fails;
///  3. verifies the result and rolls back if the target is somehow missing.
///
/// A hard kill exactly between the two renames still cannot be repaired from
/// inside the dying process; the installer heals that state instead (see
/// `site/install.ps1`: `fa.exe` missing + `fa.exe.old` present → restore), and
/// a later `fa update` restores it before swapping too.
library;

import 'dart:io';

/// Renames [from] onto [to] — the seam tests use to fail a rename
/// deterministically.
typedef SwapRename = void Function(String from, String to);

void _defaultRename(String from, String to) => File(from).renameSync(to);

/// Replaces [target] with [staging].
///
/// [isWindows] and [rename] are test seams; production callers pass neither.
/// On non-Windows the previous binary is kept as `<target>.bak` and the staged
/// file is made executable through [runProcess] (`chmod +x`), matching the
/// behaviour every other platform had.
///
/// Throws [StateError] when the staged file is unusable, and rethrows a
/// failing rename after restoring the previous binary.
Future<void> swapBinary({
  required String staging,
  required String target,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
  runProcess,
  bool? isWindows,
  SwapRename? rename,
}) async {
  final move = rename ?? _defaultRename;
  final staged = File(staging);
  if (!staged.existsSync() || staged.lengthSync() == 0) {
    throw StateError(
      'update aborted: the staged binary "$staging" is missing or empty - '
      '"$target" was left untouched',
    );
  }

  if (!(isWindows ?? Platform.isWindows)) {
    if (File(target).existsSync()) {
      // One-generation rollback copy, overwritten on every update.
      await File(target).copy('$target.bak');
    }
    move(staging, target);
    if (runProcess != null) {
      await runProcess('chmod', <String>['+x', target]);
    }
    return;
  }

  final aside = '$target.old';
  if (!File(target).existsSync()) {
    // Already in the broken state of an earlier interrupted update (the live
    // binary gone, the previous one parked): put it back and swap over it.
    // The stale-aside cleanup below must NOT run before this check - it would
    // delete the only runnable binary on the machine.
    if (File(aside).existsSync()) {
      move(aside, target);
    } else {
      throw StateError(
        'update aborted: neither "$target" nor "$aside" exists - reinstall '
        'from the installer',
      );
    }
  }

  try {
    // A stale aside from a previous update: the live binary is about to take
    // its place, so the leftover copy carries no information.
    File(aside).deleteSync();
  } on PathNotFoundException {
    // Nothing to clean up — the normal case on a clean install.
  }

  move(target, aside);
  try {
    move(staging, target);
  } on Object {
    // The parked copy is the only runnable binary left: put it back before
    // surfacing the failure, so the user keeps a working `fa`.
    if (!File(target).existsSync() && File(aside).existsSync()) {
      try {
        move(aside, target);
      } on Object {
        // The rollback itself failed; the rethrow still reports the original
        // failure and the aside keeps the binary recoverable by hand.
      }
    }
    rethrow;
  }

  if (!File(target).existsSync()) {
    // A rename that "succeeded" but produced nothing is not something to
    // trust: restore the previous binary and fail loudly.
    if (File(aside).existsSync()) {
      move(aside, target);
    }
    throw StateError(
      'update aborted: "$target" is missing after the swap - the previous '
      'binary was restored',
    );
  }
}
