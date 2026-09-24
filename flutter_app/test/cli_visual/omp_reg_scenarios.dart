/// The pinned shared-scenario data for the omp REG parity story (issue
/// #810): the SAME canned SSE drives BOTH CLIs — the omp reference capture
/// (`omp_ref_capture_test.dart`) and the fa-side REG visual leg
/// (`fa_omp_reg_visual_test.dart`) — so any structural difference on a
/// shared surface is a real renderer difference, not a data difference.
///
/// Keep the mock model id / prompts in sync with the root REG suite
/// (`test/cli/omp_reg_parity_test.dart`), which scripts the same snapshot
/// into fa's status-line engine.
library;

/// The omp build the reference fixtures were captured against
/// (`can1357/oh-my-pi`). Provenance.json must pin the same commit; the root
/// REG suite asserts it.
const kRegOmpCommit = 'df624f56b';

/// The mock provider's model id, used on BOTH sides:
/// - omp: booted with `--model mockcap/$kRegModelId` against the mock;
/// - fa: config.yaml provider entry with the same modelId.
const kRegModelId = 'test-model';

/// Unique marker inside note.md — the tool-turn wait anchor on both sides
/// (the toolResultEcho response streams the file content back, so the
/// marker lands on screen only after the read actually ran).
const kRegNoteMarker = 'note-7f3a';

/// The two user turns the REG scenarios drive (beyond the boot screen).
const kRegPrompts = {
  'tool_call': 'Read the note.',
  'code_block': 'Show a snippet.',
};

/// The scripted OpenAI-compatible conversation both CLIs consume.
/// Tool-call turn: request 1 returns the `read` call, request 2 echoes the
/// real tool result (proves the result flowed through THE CLI's executor),
/// request 3 closes the turn. Code-block turn: a fenced dart snippet.
const kRegMockScriptYaml =
    '''
model: mockcap/$kRegModelId
scenarios:
  - match: 'Read the note.'
    responses:
      - toolCall:
          name: read
          arguments: '{"path": "note.md"}'
      - toolResultEcho: true
      - text: 'turn complete'
  - match: 'Show a snippet.'
    responses:
      - text: |
            ```dart
            print('hello omp parity')
            ```
            fenced snippet shown
''';

/// note.md content written into the shared git-clean capture cwd — both
/// CLIs' `read` tool resolves the relative `note.md` against their own cwd
/// and finds the same bytes.
const kRegNoteContent = '# note\n$kRegNoteMarker read ok\n';
