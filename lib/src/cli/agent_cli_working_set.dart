// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C1 — the CLI's working-set observability (`part of` so it sees
/// the library-private CLI surface): [_onWorkingSetSaved], the main
/// agent's store callback — ONE dim line per stored write and the
/// `working_set` HEP frame (size + time only — never the text, I8).
part of 'agent_cli.dart';

extension AgentCliWorkingSet on AgentCli {
  /// The store callback (gh-2423 C1): one dim line + one HEP frame per
  /// stored write. Never the text (I8).
  void _onWorkingSetSaved(WorkingSetSaveResult result) {
    final snapshot = result.snapshot;
    final line = result.cleared
        ? 'working set cleared'
        : 'working set updated (${snapshot.chars} chars'
              '${result.redactions > 0 ? ', ${result.redactions} redacted' : ''})';
    io.writeln(_style.dim(line));
    final local = snapshot.updatedAt.toLocal();
    final hhmm =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    _hep?.workingSet(
      chars: snapshot.chars,
      updated: hhmm,
      cleared: result.cleared,
    );
  }
}
