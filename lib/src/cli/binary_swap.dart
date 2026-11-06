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
/// The swap now validates the staged file, heals an already-broken install,
/// rolls the parked binary back when the swap-in fails, and verifies the
/// result. A hard kill exactly between the two renames still cannot be
/// repaired from inside the dying process; the installer heals that state
/// (`site/install.ps1`: `fa.exe` missing + `fa.exe.old` present → restore) and
/// a later update heals it before swapping.
library;

import 'dart:io';

/// Renames [from] onto [to] — the seam tests use to fail a rename
/// deterministically.
typedef SwapRename = void Function(String from, String to);

/// Runs a helper process (only `chmod +x` on Unix today).
typedef SwapRunProcess =
    Future<ProcessResult> Function(String executable, List<String> arguments);

void _defaultRename(String from, String to) => File(from).renameSync(to);

/// Replaces [target] with [staging].
///
/// [isWindows] and [rename] are test seams; production callers pass neither.
/// On non-Windows the previous binary is kept as `<target>.bak` and the staged
/// file is made executable through [runProcess] (`chmod +x`), matching the
/// behaviour every other platform had.
///
/// Throws [StateError] when the staged file is unusable or the install cannot
/// be repaired, and rethrows a failing rename after restoring the previous
/// binary.
Future<void> swapBinary({
  required String staging,
  required String target,
  SwapRunProcess? runProcess,
  bool? isWindows,
  SwapRename? rename,
}) async {
  final move = rename ?? _defaultRename;
  _requireUsableStaging(staging);
  if (isWindows ?? Platform.isWindows) {
    _swapWindows(staging, target, move);
    return;
  }
  await _swapUnix(staging, target, move, runProcess);
}

/// Aborts before the live binary is touched when the download/extract produced
/// nothing — the fingerprint of a failed update.
void _requireUsableStaging(String staging) {
  final staged = File(staging);
  if (staged.existsSync() && staged.lengthSync() > 0) return;
  throw StateError(
    'update aborted: the staged binary "$staging" is missing or empty - '
    'the installed binary was left untouched',
  );
}

Future<void> _swapUnix(
  String staging,
  String target,
  SwapRename move,
  SwapRunProcess? runProcess,
) async {
  if (File(target).existsSync()) {
    // One-generation rollback copy, overwritten on every update.
    await File(target).copy('$target.bak');
  }
  move(staging, target);
  if (runProcess != null) await runProcess('chmod', <String>['+x', target]);
}

void _swapWindows(String staging, String target, SwapRename move) {
  final aside = '$target.old';
  _healBrokenInstall(target, aside, move);
  _deleteStaleAside(aside);
  move(target, aside);
  _moveStagingIntoPlace(staging, target, aside, move);
  _requireTargetAfterSwap(target, aside, move);
}

/// Puts the parked binary back when an earlier interrupted update left the
/// install without one, so the swap has something to park.
void _healBrokenInstall(String target, String aside, SwapRename move) {
  if (File(target).existsSync()) return;
  if (!File(aside).existsSync()) {
    throw StateError(
      'update aborted: neither "$target" nor "$aside" exists - reinstall '
      'from the installer',
    );
  }
  // Must run BEFORE the stale-aside cleanup below: deleting the parked copy
  // first would destroy the only runnable binary on the machine.
  move(aside, target);
}

/// Removes the previous generation's side copy. A transiently locked file (an
/// antivirus or the search indexer holding it) aborts with a named error
/// instead of a raw [FileSystemException] the caller cannot act on.
void _deleteStaleAside(String aside) {
  try {
    File(aside).deleteSync();
  } on PathNotFoundException {
    return; // the normal case on a clean install
  } on FileSystemException catch (error) {
    final reason = error.osError?.message ?? error.message;
    throw StateError(
      'update aborted: could not remove the previous side copy "$aside" '
      '($reason) - an antivirus or indexer may be holding it; retry in a '
      'moment. The running binary is unchanged',
    );
  }
}

/// Moves the staged file into place, restoring the parked binary first if the
/// rename fails (the parked copy would otherwise be the only runnable one).
void _moveStagingIntoPlace(
  String staging,
  String target,
  String aside,
  SwapRename move,
) {
  try {
    move(staging, target);
  } on Object {
    _restoreParkedBinary(target, aside, move);
    rethrow;
  }
}

/// A rename that "succeeded" but produced no target is not something to trust.
void _requireTargetAfterSwap(String target, String aside, SwapRename move) {
  if (File(target).existsSync()) return;
  _restoreParkedBinary(target, aside, move);
  throw StateError(
    'update aborted: "$target" is missing after the swap - the previous '
    'binary was restored',
  );
}

/// Best-effort rollback: put the parked binary back when the target is gone.
void _restoreParkedBinary(String target, String aside, SwapRename move) {
  if (File(target).existsSync() || !File(aside).existsSync()) return;
  try {
    move(aside, target);
  } on Object {
    // The caller rethrows the original failure either way; the aside keeps
    // the binary recoverable by hand.
  }
}
