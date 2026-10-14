// REG guard for gh-1547 review threads (tui_editor fork sync): the vendored
// composer copy of the dart_tui fork editor deliberately RENAMES the fork's
// public `undoStack` field to the private `_undoStack` (initializing formal;
// `library_private_types_in_public_api` INFO fix). The file header used to
// claim "Otherwise byte-identical to the fork source" while the field
// diverged undocumented — the next "re-sync from the fork" edit would copy
// the public field back over and reintroduce the INFO, which the new
// `--fatal-infos` CI gate fails on.
//
// Hermetic source grep (no PTY, no network), same pattern as
// `conflict_markers_reg_test.dart`: the deviation must stay documented in
// the header so a future fork re-sync keeps the rename on purpose.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('vendored tui_editor documents its deliberate fork deviation '
      '(undoStack → _undoStack, gh-1547)', () {
    final source = File('lib/src/cli/tui_editor.dart').readAsStringSync();

    // The deviation itself must still be in place: the copy carries the
    // PRIVATE field, not the fork's public `undoStack` declaration.
    expect(
      source,
      contains('final List<_UndoStep> _undoStack;'),
      reason:
          'the documented deviation vanished — either the rename was '
          'reverted (public fork field restored, reintroducing the '
          'library_private_types_in_public_api INFO that the '
          '--fatal-infos CI gate fails on) or the field was restructured; '
          'update this guard and the header note together',
    );

    // The header must mark the divergence as deliberate, name both
    // spellings, and bind the keep-on-re-sync instruction — all before
    // the `library;` directive so it is part of the sync contract block.
    final headerEnd = source.indexOf('library;');
    expect(
      headerEnd,
      greaterThan(0),
      reason:
          'doc header must precede '
          'the library directive',
    );
    final header = source.substring(0, headerEnd);
    expect(
      header,
      contains('DEVIATES from the fork'),
      reason:
          'the header still claims byte-identity with the fork while '
          'undoStack is _undoStack here — a future fork re-sync would '
          'silently reintroduce the public field (gh-1547)',
    );
    expect(header, contains('_undoStack'));
    expect(header, contains('undoStack'));
    expect(
      header.toLowerCase(),
      contains('re-sync'),
      reason: 'the note must instruct the re-syncer to KEEP the rename',
    );
  });
}
