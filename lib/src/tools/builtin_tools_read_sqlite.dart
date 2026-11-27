/// SQLite target reads for the `read` tool (omp's `#readSqlite`): candidate probing, read-only open, and the selector views (table list, schema+sample, single row, paged query, raw query). Split out of `builtin_tools.dart` to keep that file under the repo line gate; same library (a `part of`), so the privates stay visible.
part of 'builtin_tools.dart';

// ---------------------------------------------------------------------------
// read: SQLite targets (omp's #readSqlite)
// ---------------------------------------------------------------------------

/// Probes [rawPath] for SQLite targets (`data.db:table?…`) and renders the
/// selected view when a candidate names an existing database file. Returns
/// null when no candidate resolves. Without a [SqliteEngine] (web hosts have
/// no FFI) a resolved target yields a clean "not supported" note instead of
/// opening the file.
Future<ToolExecutionResult?> _tryReadSqlite(
  ExecutionEnv env,
  String rawPath,
  SqliteEngine? engine,
) async {
  final candidates = parseSqlitePathCandidates(rawPath);
  for (final candidate in candidates) {
    final info = await env.fileInfo(candidate.sqlitePath);
    if (info.isErr) continue;
    if (info.valueOrNull!.kind != FileKind.file) continue;
    return _readSqliteTarget(env, candidate, engine);
  }
  return null;
}

/// Opens the resolved SQLite [candidate] read-only and renders its selected
/// view (omp's `#readSqlite`). Without a [SqliteEngine] (web hosts have no
/// FFI) yields a clean "not supported" note instead of opening the file.
Future<ToolExecutionResult> _readSqliteTarget(
  ExecutionEnv env,
  SqlitePathCandidate candidate,
  SqliteEngine? engine,
) async {
  final selector = parseSqliteSelector(
    candidate.subPath,
    candidate.queryString,
  );
  if (engine == null) {
    return ToolExecutionResult.text(
      '[SQLite database reads are not supported in this environment '
      '(no SQLite engine available); ${candidate.sqlitePath} was not '
      'opened.]',
    );
  }

  final absolute =
      (await env.absolutePath(candidate.sqlitePath)).valueOrNull ??
      candidate.sqlitePath;
  SqliteDatabase? db;
  try {
    db = engine.openReadOnly(absolute);
    return _renderSqliteSelector(db, selector);
  } on StateError {
    rethrow;
  } on Object catch (error) {
    // Engine/backend failures (e.g. "file is not a database") surface as
    // the tool's error channel, mirroring omp's ToolError wrap.
    throw StateError('$error');
  } finally {
    db?.close();
  }
}

/// Renders one parsed SQLite selector against the open database (omp's
/// selector views: table list, schema+sample, single row, paged query, raw
/// query).
ToolExecutionResult _renderSqliteSelector(
  SqliteDatabase db,
  SqliteSelector selector,
) {
  switch (selector) {
    case SqliteListSelector():
      final tables = listSqliteTables(db)
          .take(maxSqliteTableListEntries)
          .toList();
      return ToolExecutionResult.text(renderSqliteTableList(tables));
    case SqliteSchemaSelector(:final table, :final sampleLimit):
      return _readSqliteSchema(db, table, sampleLimit);
    case SqliteRowSelector(:final table, :final key):
      return _readSqliteRow(db, table, key);
    case SqliteQuerySelector(
      :final table,
      :final limit,
      :final offset,
      :final order,
      :final where,
    ):
      return _readSqliteTablePage(
        db,
        table,
        limit: limit,
        offset: offset,
        order: order,
        where: where,
      );
    case SqliteRawSelector(:final sql):
      return _readSqliteRawQuery(db, sql);
  }
}

/// Renders a single row looked up by key (omp's row view), or the "no row"
/// note when the key matches nothing.
ToolExecutionResult _readSqliteRow(
  SqliteDatabase db,
  String table,
  String key,
) {
  final lookup = resolveSqliteRowLookup(db, table);
  final row = getSqliteRow(db, table, lookup, key);
  if (row == null) {
    return ToolExecutionResult.text(
      "No row found in table '$table' for key '$key'.",
    );
  }
  return ToolExecutionResult.text(renderSqliteRow(row));
}

/// Renders one page of a table query (omp's paged-query view).
ToolExecutionResult _readSqliteTablePage(
  SqliteDatabase db,
  String table, {
  required int limit,
  required int offset,
  required String? order,
  required String? where,
}) {
  final page = querySqliteRows(
    db,
    table,
    limit: limit,
    offset: offset,
    order: order,
    where: where,
  );
  return ToolExecutionResult.text(
    renderSqliteTable(
      page.columns,
      page.rows,
      totalCount: page.totalCount,
      offset: offset,
      limit: limit,
      table: table,
    ),
  );
}

/// Renders a raw `q=SELECT …` query result (omp's raw-query view), with the
/// row-cap notice when the engine truncated the result.
ToolExecutionResult _readSqliteRawQuery(SqliteDatabase db, String sql) {
  final result = executeSqliteReadQuery(db, sql);
  var output = renderSqliteTable(
    result.columns,
    result.rows,
    totalCount: result.rows.length,
    offset: 0,
    limit: result.rows.isEmpty ? defaultToolMaxLines : result.rows.length,
    table: 'query',
  );
  if (result.truncated) {
    output +=
        '\n[Output capped at $maxSqliteRawQueryRows rows; add a '
        'LIMIT/OFFSET clause to the query to page through more]';
  }
  return ToolExecutionResult.text(output);
}

/// Renders a table schema plus the first sample page (omp's schema view),
/// with a continuation hint when the table has more rows than the sample.
ToolExecutionResult _readSqliteSchema(
  SqliteDatabase db,
  String table,
  int sampleLimit,
) {
  final sample = querySqliteRows(db, table, limit: sampleLimit, offset: 0);
  var output = renderSqliteSchema(
    getSqliteTableSchema(db, table),
    SqliteRows(columns: sample.columns, rows: sample.rows),
  );
  if (sample.rows.length < sample.totalCount) {
    final remaining = sample.totalCount - sample.rows.length;
    output +=
        '\n[$remaining more rows; append '
        ':$table?limit=$defaultSqliteQueryLimit&offset=${sample.rows.length} '
        'to the database path to continue]';
  }
  return ToolExecutionResult.text(output);
}
