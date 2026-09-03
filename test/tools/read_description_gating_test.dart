/// Capability gating of the `read` tool description (issue #19 AC2/AC18):
/// the SQLite subsection is a `{{sqlite}}` chunk substituted only when the
/// host provides a [SqliteEngine]. The golden string below was captured from
/// the pre-split `readToolDescriptionPrompt` with `{{maxLines}}` and
/// `{{maxBytesKb}}` already substituted, so byte-identity with today's
/// description is proven when SQLite is available; without an engine the
/// section bytes must disappear cleanly (no tokens, no double blank lines).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart';
import 'package:test/test.dart';

/// The SQLite section bytes exactly as they appear in the golden
/// description: heading, blank line, paragraph, and the trailing blank line
/// separating the section from `## Hashline mode`.
const _sqliteSection =
    '## SQLite databases\n\nWhen the host supports it, `.db`/`.db3`/`.sqlite`/`.sqlite3` paths read as databases: `data.db` lists tables, `data.db:table` shows the schema plus sample rows, `data.db:table:key` fetches one row by primary key (or rowid), `data.db:table?limit=20&offset=40&order=col:desc&where=...` pages a table, and `data.db?q=SELECT ...` runs a raw read-only query.\n\n';

/// The pre-split `read` tool description (golden).
const _goldenDescription =
    'Read the contents of a text file or image. Text output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large text files. Images are returned as base64 content.\n\n## Path selectors\n\nAppend a trailing selector to `path` to read exactly the lines you need:\n\n- `:N` — start at line N (1-indexed), through end of file. `:N-` is the same.\n- `:A-B` — inclusive line range (`:A..B` works too).\n- `:A+C` — C lines starting at A.\n- `:R1,R2,…` — multiple ranges, sorted and merged (`:5-16,960-973`); blocks are joined with a `…` separator and ranges past end of file are reported as skipped.\n- `:raw` — verbatim content: no line numbers, no hashline header, no notices. Combine as `:raw:50-100` or `:50-100:raw`.\n\nDo not combine `offset`/`limit` with a path selector. Selectors only apply to text files (not images).\n\n## Archives\n\nRead inside `.zip`, `.tar`, `.tar.gz`/`.tgz` files: `archive.zip` lists the root, `archive.zip:dir/` lists a directory, `archive.zip:inner/file.txt` reads a member (selectors apply, e.g. `archive.zip:inner/file.txt:50-60`). Binary members return a note.\n\n## SQLite databases\n\nWhen the host supports it, `.db`/`.db3`/`.sqlite`/`.sqlite3` paths read as databases: `data.db` lists tables, `data.db:table` shows the schema plus sample rows, `data.db:table:key` fetches one row by primary key (or rowid), `data.db:table?limit=20&offset=40&order=col:desc&where=...` pages a table, and `data.db?q=SELECT ...` runs a raw read-only query.\n\n## Hashline mode\n\nSet hashline=true to prefix lines with line numbers and a [path#TAG] content-hash header for anchoring hashline edit patches (line numbers stay correct on ranged reads). Suppressed by `:raw`.';

/// Trivial engine: description assembly never opens a database.
class _UnusedSqliteEngine implements SqliteEngine {
  @override
  SqliteDatabase openReadOnly(String path) =>
      throw UnimplementedError('description assembly never opens a database');
}

void main() {
  final env = MemoryExecutionEnv(cwd: '/work');

  test('the read prompt template carries exactly one {{sqlite}} token', () {
    expect('{{sqlite}}'.allMatches(readToolDescriptionPrompt).length, 1);
  });

  test(
    'with an engine the description is byte-identical to the pre-split one',
    () {
      final tool = readFileTool(env, sqlite: _UnusedSqliteEngine());
      expect(tool.description, _goldenDescription);
    },
  );

  test('without an engine the description is the golden minus the section', () {
    final tool = readFileTool(env);
    expect(
      tool.description,
      _goldenDescription.replaceFirst(_sqliteSection, ''),
    );
  });

  test('without an engine no SQLite trace, token, or double blanks remain', () {
    final description = readFileTool(env).description;
    expect(description.contains('SQLite'), isFalse);
    expect(description.contains('{{'), isFalse);
    expect(
      description.contains('\n\n\n'),
      isFalse,
      reason: 'no double blank lines',
    );
    for (final section in [
      '## Path selectors',
      '## Archives',
      '## Hashline mode',
    ]) {
      expect(description, contains(section));
    }
  });
}
