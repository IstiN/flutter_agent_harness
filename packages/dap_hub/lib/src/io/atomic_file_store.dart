// Atomic (tmp + rename) JSON file persistence — the dart:io [HubStore].
//
// Port of the Go store.go writeAtomic/loadChannels file handling.

import 'dart:io';

import '../persistence.dart';

/// Persists one document at [path] atomically: writes a tmp file beside
/// it (0600), then renames over the target.
final class AtomicFileStore implements HubStore {
  const AtomicFileStore(this.path);

  /// The backing file path.
  final String path;

  /// The file contents, or null when missing/unreadable (first boot is
  /// not an error).
  @override
  Future<String?> read() async {
    try {
      return await File(path).readAsString();
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String contents) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(contents, mode: FileMode.write, flush: true);
    await tmp.rename(path);
  }
}
