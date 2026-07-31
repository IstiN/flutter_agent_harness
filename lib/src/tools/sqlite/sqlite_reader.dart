/// SQLite targets for the `read` tool, ported from oh-my-pi
/// `packages/coding-agent/src/tools/sqlite-reader.ts`: `db.sqlite` lists
/// tables, `db.sqlite:table` renders the schema plus sample rows,
/// `db.sqlite:table:key` looks a row up by primary key (or rowid),
/// `db.sqlite:table?limit=…&offset=…&order=…&where=…` pages a table, and
/// `db.sqlite?q=SELECT …` runs a raw read-only query — all rendered as
/// width-capped ASCII tables.
///
/// This module is pure Dart: database access goes through the [SqliteEngine]
/// interface so the core package stays web-compilable. The FFI-backed engine
/// (`package:sqlite3`) is exported only from `lib/io.dart`; hosts without FFI
/// (web) construct the `read` tool without an engine and get a clean
/// "not supported" note for SQLite paths.
///
/// Deliberate deviations from omp:
///
/// - Table listings count exactly with a bounded probe
///   ([rowCountProbeCap]); omp's `sqlite_stat1` planner-estimate fast path is
///   not ported.
/// - Cell widths are measured in UTF-16 code units (`String.length`), not
///   display cells — wide glyphs may overflow the 120-column frame.
/// - Database detection is by extension + existence only; omp additionally
///   sniffs the SQLite magic header, which would require reading the file
///   through the harness's whole-file [FileSystem] API. A non-SQLite file
///   with a matching extension fails at open/query time instead.
library;

import 'dart:typed_data';

import '../tool_format.dart';

/// Default row limit for table queries (omp's DEFAULT_QUERY_LIMIT).
const defaultSqliteQueryLimit = 20;

/// Sample row count shown with a table schema (omp's
/// DEFAULT_SCHEMA_SAMPLE_LIMIT).
const defaultSqliteSchemaSampleLimit = 5;

/// Hard cap on an explicit `?limit=` (omp's MAX_QUERY_LIMIT).
const maxSqliteQueryLimit = 500;

/// Row cap for raw `?q=` SQL — protects against `SELECT *` on
/// multi-million-row tables (omp's MAX_RAW_QUERY_ROWS).
const maxSqliteRawQueryRows = 1000;

/// Cap on the rendered table list (omp's `#readSqlite` list limit).
const maxSqliteTableListEntries = 500;

/// Maximum ASCII-table render width (omp's MAX_RENDER_WIDTH).
const maxSqliteRenderWidth = 120;

/// Maximum per-column render width (omp's MAX_COLUMN_WIDTH).
const maxSqliteColumnWidth = 40;

/// Floor for each ASCII-table column; below it every multi-char cell would
/// collapse to a lone ellipsis (omp's MIN_COLUMN_WIDTH, issue #3107).
const _minColumnWidth = 3;

/// Separator overhead per column in the ASCII table (`" | "`).
const _columnSeparatorWidth = 3;

/// Constant frame overhead added once to every row (leading `"|"`).
const _tableFrameWidth = 1;

/// Upper bound on rows scanned when counting a table for the listing. SQLite
/// has no stored row count, so `COUNT(*)` is a full b-tree scan; the listing
/// counts exactly only when a table is provably small, reading at most this
/// many rows (omp's ROW_COUNT_PROBE_CAP).
const rowCountProbeCap = 50000;

/// `PRAGMA busy_timeout` applied on open (omp: 3000 ms).
const sqliteBusyTimeoutMs = 3000;

// ---------------------------------------------------------------------------
// Engine interface (implemented by the FFI host; see lib/io.dart)
// ---------------------------------------------------------------------------

/// A query result: column names plus rows as column→value maps.
final class SqliteRows {
  /// Creates a result.
  const SqliteRows({
    required this.columns,
    required this.rows,
    this.truncated = false,
  });

  /// Column names in result order.
  final List<String> columns;

  /// Rows keyed by column name (duplicate names: last value wins).
  final List<Map<String, Object?>> rows;

  /// Whether more rows were available beyond the requested cap.
  final bool truncated;
}

/// An open SQLite database. All methods are synchronous: the underlying FFI
/// calls are synchronous too.
abstract interface class SqliteDatabase {
  /// Runs [sql] with positional [parameters] and returns the rows. When
  /// [maxRows] is given, iteration stops after that many rows and
  /// [SqliteRows.truncated] reports whether more were available.
  SqliteRows select(
    String sql, {
    List<Object?> parameters = const [],
    int? maxRows,
  });

  /// The number of bound parameters [sql] expects.
  int parameterCount(String sql);

  /// Runs [sql] without returning rows (e.g. `PRAGMA`).
  void execute(String sql);

  /// Closes the database.
  void close();
}

/// Opens SQLite databases for the `read` tool. The FFI-backed implementation
/// lives behind `lib/io.dart`; web hosts pass no engine.
abstract interface class SqliteEngine {
  /// Opens [path] read-only.
  SqliteDatabase openReadOnly(String path);
}

// ---------------------------------------------------------------------------
// Path candidates (omp's parseSqlitePathCandidates)
// ---------------------------------------------------------------------------

/// One `{sqlitePath, subPath, queryString}` split of a
/// `db.sqlite:table?query` reference (omp's SqlitePathCandidate).
final class SqlitePathCandidate {
  /// Creates a candidate.
  const SqlitePathCandidate(this.sqlitePath, this.subPath, this.queryString);

  /// Path to the database file itself.
  final String sqlitePath;

  /// Table/row selector after the database path.
  final String subPath;

  /// Query string after the first `?` (may be empty).
  final String queryString;
}

final _sqlitePathPattern = RegExp(
  r'\.(?:sqlite3?|db3?)(?=(?::|\?|$))',
  caseSensitive: false,
);

({String subPath, String queryString}) _splitSqliteRemainder(String remainder) {
  final queryIndex = remainder.indexOf('?');
  if (queryIndex == -1) {
    return (
      subPath: remainder.replaceFirst(RegExp('^:+'), ''),
      queryString: '',
    );
  }
  return (
    subPath: remainder.substring(0, queryIndex).replaceFirst(RegExp('^:+'), ''),
    queryString: remainder.substring(queryIndex + 1),
  );
}

/// Splits a `db.sqlite:table?query` reference into every plausible
/// candidate, longest database prefix first (omp's
/// `parseSqlitePathCandidates`). Database detection is by extension only;
/// existence and readability are checked by the caller.
List<SqlitePathCandidate> parseSqlitePathCandidates(String filePath) {
  final normalized = filePath.replaceAll('\\', '/');
  final seen = <String>{};
  final candidates = <SqlitePathCandidate>[];
  for (final match in _sqlitePathPattern.allMatches(normalized)) {
    final end = match.end;
    final sqlitePath = filePath.substring(0, end);
    final remainder = normalized.substring(end);
    final (:subPath, :queryString) = _splitSqliteRemainder(remainder);
    final key = '$sqlitePath\x00$subPath\x00$queryString';
    if (!seen.add(key)) continue;
    candidates.add(SqlitePathCandidate(sqlitePath, subPath, queryString));
  }
  candidates.sort((a, b) => b.sqlitePath.length.compareTo(a.sqlitePath.length));
  return candidates;
}

// ---------------------------------------------------------------------------
// Selector grammar (omp's parseSqliteSelector)
// ---------------------------------------------------------------------------

/// The parsed SQLite target selector (omp's SqliteSelector).
sealed class SqliteSelector {
  const SqliteSelector();
}

/// `db.sqlite` — list non-`sqlite_%` tables with row counts.
final class SqliteListSelector extends SqliteSelector {
  /// Creates a list selector.
  const SqliteListSelector();
}

/// `db.sqlite:table` — schema plus sample rows.
final class SqliteSchemaSelector extends SqliteSelector {
  /// Creates a schema selector.
  const SqliteSchemaSelector(
    this.table, {
    this.sampleLimit = defaultSqliteSchemaSampleLimit,
  });

  /// Table name.
  final String table;

  /// Number of sample rows to render.
  final int sampleLimit;
}

/// `db.sqlite:table:key` — row lookup by primary key (or rowid).
final class SqliteRowSelector extends SqliteSelector {
  /// Creates a row selector.
  const SqliteRowSelector(this.table, this.key);

  /// Table name.
  final String table;

  /// Key value as written in the path.
  final String key;
}

/// `db.sqlite:table?limit=…&offset=…&order=…&where=…` — paged table query.
final class SqliteQuerySelector extends SqliteSelector {
  /// Creates a query selector.
  const SqliteQuerySelector({
    required this.table,
    required this.limit,
    required this.offset,
    this.order,
    this.where,
  });

  /// Table name.
  final String table;

  /// Row limit (capped at [maxSqliteQueryLimit]).
  final int limit;

  /// Row offset.
  final int offset;

  /// Optional `column` or `column:asc|desc` ordering.
  final String? order;

  /// Optional WHERE clause (validated; no comments, terminators, or control
  /// keywords).
  final String? where;
}

/// `db.sqlite?q=SELECT …` — raw read-only SQL.
final class SqliteRawSelector extends SqliteSelector {
  /// Creates a raw selector.
  const SqliteRawSelector(this.sql);

  /// The SQL to run.
  final String sql;
}

int _parseLimit(String? value, int fallback) {
  if (value == null || value.trim().isEmpty) return fallback;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 1) {
    throw StateError("SQLite limit must be a positive integer; got '$value'");
  }
  return parsed < maxSqliteQueryLimit ? parsed : maxSqliteQueryLimit;
}

int _parseOffset(String? value) {
  if (value == null || value.trim().isEmpty) return 0;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 0) {
    throw StateError(
      "SQLite offset must be a non-negative integer; got '$value'",
    );
  }
  return parsed;
}

const _forbiddenWhereKeywords = {
  'limit',
  'offset',
  'union',
  'intersect',
  'except',
  'attach',
  'detach',
  'pragma',
};

const _commentOrTerminatorError =
    "SQLite 'where' clause must not contain comments or statement "
    "terminators; use '?q=SELECT ...' for raw SQL";
const _forbiddenKeywordError =
    "SQLite 'where' clause must not contain LIMIT/OFFSET/UNION/INTERSECT/"
    "EXCEPT/ATTACH/DETACH/PRAGMA; use '?q=SELECT ...' for raw SQL";

/// Returns the index of the quote that closes the string literal opening at
/// [start] (`sql[start]` is the quote character), or `sql.length` when the
/// literal is unterminated. Doubled quotes (`''`/`""`) escape inside the
/// literal.
int _skipQuotedLiteral(String sql, int start) {
  final quote = sql[start];
  var index = start + 1;
  while (index < sql.length) {
    if (sql[index] == quote) {
      if (index + 1 < sql.length && sql[index + 1] == quote) {
        index += 2;
        continue;
      }
      return index;
    }
    index += 1;
  }
  return sql.length;
}

/// Whether [char]/[next] open a SQL comment or statement terminator outside
/// a string literal (`;`, `--`, `/*`, or `*/`).
bool _isWhereClauseControl(String? char, String? next) {
  return char == ';' ||
      (char == '-' && next == '-') ||
      (char == '/' && next == '*') ||
      (char == '*' && next == '/');
}

/// Scans [sql] for a comment or statement terminator outside string
/// literals; returns the violation message or null.
String? _whereClauseControlViolation(String sql) {
  var index = 0;
  while (index < sql.length) {
    final char = sql[index];
    if (char == "'" || char == '"') {
      index = _skipQuotedLiteral(sql, index) + 1;
      continue;
    }
    final next = index + 1 < sql.length ? sql[index + 1] : null;
    if (_isWhereClauseControl(char, next)) {
      return _commentOrTerminatorError;
    }
    index += 1;
  }
  return null;
}

/// The character at [index], or null past the end of [sql].
String? _whereClauseCharAt(String sql, int index) {
  return index < sql.length ? sql[index] : null;
}

/// Whether [char] continues an identifier token (`[A-Za-z0-9_]`).
bool _isWhereClauseIdentChar(String? char) {
  return char != null && RegExp(r'[A-Za-z0-9_]').hasMatch(char);
}

/// Splits [sql] into lowercased identifier tokens (`[A-Za-z0-9_]` runs)
/// outside string literals.
List<String> _whereClauseTokens(String sql) {
  final tokens = <String>[];
  var tokenStart = -1;
  var index = 0;
  while (index <= sql.length) {
    final char = _whereClauseCharAt(sql, index);
    if (_isWhereClauseIdentChar(char)) {
      if (tokenStart < 0) tokenStart = index;
    } else {
      if (tokenStart >= 0) {
        tokens.add(sql.substring(tokenStart, index).toLowerCase());
        tokenStart = -1;
      }
      if (char == "'" || char == '"') {
        index = _skipQuotedLiteral(sql, index);
      }
    }
    index += 1;
  }
  return tokens;
}

/// Scans a `where=` clause character-by-character, tracking single- and
/// double-quoted string literals, and rejects SQL control syntax that would
/// otherwise let the structured helper path escape the bound
/// `LIMIT ? OFFSET ?` pagination (omp's `findWhereClauseViolation`). A
/// comment/terminator anywhere in the clause wins over a forbidden keyword
/// (omp returns the comment error as soon as the scan reaches it).
String? _findWhereClauseViolation(String sql) {
  final controlViolation = _whereClauseControlViolation(sql);
  if (controlViolation != null) return controlViolation;
  for (final token in _whereClauseTokens(sql)) {
    if (_forbiddenWhereKeywords.contains(token)) {
      return _forbiddenKeywordError;
    }
  }
  return null;
}

String? _validateWhereClause(String? where) {
  if (where == null) return null;
  final trimmed = where.trim();
  if (trimmed.isEmpty) return null;
  final violation = _findWhereClauseViolation(trimmed);
  if (violation != null) throw StateError(violation);
  return trimmed;
}

/// The `q=` raw-query stage of [parseSqliteSelector]: returns null when
/// there is no `q` parameter, else the raw selector (omp rejects combining
/// raw queries with table selectors or pagination, and empty queries).
SqliteSelector? _parseRawQuerySelector(
  String normalizedSubPath,
  Map<String, String> params,
) {
  final rawQuery = params['q'];
  if (rawQuery == null) return null;
  final otherKeys = params.keys.where((key) => key != 'q');
  if (normalizedSubPath.isNotEmpty || otherKeys.isNotEmpty) {
    throw StateError(
      'SQLite raw queries cannot be combined with table selectors or '
      'pagination',
    );
  }
  if (rawQuery.trim().isEmpty) {
    throw StateError("SQLite query parameter 'q' cannot be empty");
  }
  return SqliteRawSelector(rawQuery);
}

/// The `table[:key]` stage of [parseSqliteSelector]: splits the row key off
/// the table name and dispatches to the row-lookup or paged-query stage.
SqliteSelector _parseTableSelector(
  String normalizedSubPath,
  Map<String, String> params,
) {
  final separatorIndex = normalizedSubPath.indexOf(':');
  final table = separatorIndex == -1
      ? normalizedSubPath
      : normalizedSubPath.substring(0, separatorIndex);
  final key = separatorIndex == -1
      ? null
      : normalizedSubPath.substring(separatorIndex + 1);
  if (table.isEmpty) {
    throw StateError('SQLite selectors must include a table name');
  }

  if (key != null && key.isNotEmpty) {
    if (params.isNotEmpty) {
      throw StateError(
        'SQLite row lookups cannot be combined with query parameters',
      );
    }
    return SqliteRowSelector(table, key);
  }

  return _parseTableQuerySelector(table, params);
}

/// The paged-query stage of [parseSqliteSelector]: validates the
/// `where`/`order` parameters, rejects unknown keys, and falls back to the
/// schema selector when no query parameters apply.
SqliteSelector _parseTableQuerySelector(
  String table,
  Map<String, String> params,
) {
  final where = _validateWhereClause(params['where']);
  final orderParam = params['order']?.trim();
  final order = orderParam == null || orderParam.isEmpty ? null : orderParam;
  final hasQueryParams =
      params.containsKey('limit') ||
      params.containsKey('offset') ||
      order != null ||
      where != null;
  if (hasQueryParams) {
    return _buildQuerySelector(table, params, order, where);
  }

  if (params.isNotEmpty) {
    throw StateError(
      "Unsupported SQLite query parameter '${params.keys.first}'",
    );
  }

  return SqliteSchemaSelector(table);
}

/// Builds the paged-query selector once any query parameter applies: rejects
/// unknown keys and parses `limit`/`offset` (omp's paged-query branch).
SqliteSelector _buildQuerySelector(
  String table,
  Map<String, String> params,
  String? order,
  String? where,
) {
  const knownKeys = {'limit', 'offset', 'order', 'where'};
  for (final keyName in params.keys) {
    if (!knownKeys.contains(keyName)) {
      throw StateError("Unsupported SQLite query parameter '$keyName'");
    }
  }
  return SqliteQuerySelector(
    table: table,
    limit: _parseLimit(params['limit'], defaultSqliteQueryLimit),
    offset: _parseOffset(params['offset']),
    order: order,
    where: where,
  );
}

/// Parses the table/query selector tail of a SQLite path (omp's
/// `parseSqliteSelector`). Throws [StateError] with omp's messages on
/// unsupported combinations.
SqliteSelector parseSqliteSelector(String subPath, String queryString) {
  final normalizedSubPath = subPath.replaceFirst(RegExp('^:+'), '').trim();
  final params = Uri.splitQueryString(queryString);

  final rawSelector = _parseRawQuerySelector(normalizedSubPath, params);
  if (rawSelector != null) return rawSelector;

  if (normalizedSubPath.isEmpty) {
    if (params.isNotEmpty) {
      throw StateError(
        'SQLite query parameters require a table selector or q=SELECT...',
      );
    }
    return const SqliteListSelector();
  }

  return _parseTableSelector(normalizedSubPath, params);
}

// ---------------------------------------------------------------------------
// Queries (omp's sqlite-reader helpers, against the engine interface)
// ---------------------------------------------------------------------------

String _quoteSqliteIdentifier(String identifier) {
  return '"${identifier.replaceAll('"', '""')}"';
}

Map<String, Object?> _getTableMasterRow(SqliteDatabase db, String table) {
  final result = db.select(
    "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT "
    "LIKE 'sqlite_%' AND name = ?",
    parameters: [table],
  );
  if (result.rows.isEmpty) {
    throw StateError("SQLite table '$table' not found");
  }
  return result.rows.first;
}

List<Map<String, Object?>> _getTableInfoRows(SqliteDatabase db, String table) {
  _getTableMasterRow(db, table);
  return db.select('PRAGMA table_info(${_quoteSqliteIdentifier(table)})').rows;
}

List<String> _getTableColumns(SqliteDatabase db, String table) {
  return [
    for (final row in _getTableInfoRows(db, table)) row['name']! as String,
  ];
}

/// Row count for a table in the listing: exact when the table is provably
/// small, otherwise a lower bound (omp's TableRowCount, minus the
/// `sqlite_stat1` estimate variant).
final class SqliteTableSummary {
  /// Creates a summary.
  const SqliteTableSummary(this.name, this.rows, {this.exact = true});

  /// Table name.
  final String name;

  /// Row count (exact, or a lower bound when [exact] is false).
  final int rows;

  /// Whether [rows] is the exact count.
  final bool exact;
}

/// Counts a table while reading at most `cap + 1` rows (omp's
/// `probeRowCount`).
SqliteTableSummary _probeRowCount(SqliteDatabase db, String table, int cap) {
  final sql =
      'SELECT COUNT(*) AS count FROM (SELECT 1 FROM '
      '${_quoteSqliteIdentifier(table)} LIMIT ${cap + 1})';
  final counted = (db.select(sql).rows.first['count']! as int);
  return counted > cap
      ? SqliteTableSummary(table, cap, exact: false)
      : SqliteTableSummary(table, counted);
}

/// Lists non-`sqlite_%` tables with bounded row counts (omp's
/// `listTables`).
List<SqliteTableSummary> listSqliteTables(
  SqliteDatabase db, {
  int probeCap = rowCountProbeCap,
}) {
  final names = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE "
    "'sqlite_%' ORDER BY name COLLATE NOCASE",
  );
  return [
    for (final row in names.rows)
      _probeRowCount(db, row['name']! as String, probeCap),
  ];
}

/// The `CREATE TABLE` statement for [table] (omp's `getTableSchema`).
String getSqliteTableSchema(SqliteDatabase db, String table) {
  final row = _getTableMasterRow(db, table);
  final sql = row['sql'] as String?;
  if (sql == null) {
    throw StateError("SQLite schema for table '$table' is unavailable");
  }
  return sql;
}

/// How a row lookup resolves: by the single primary-key column, or by rowid
/// (omp's SqliteRowLookup).
sealed class SqliteRowLookup {
  const SqliteRowLookup();
}

/// Lookup by primary-key column.
final class SqlitePkLookup extends SqliteRowLookup {
  /// Creates a PK lookup.
  const SqlitePkLookup(this.column, this.type);

  /// The primary-key column name.
  final String column;

  /// The column's declared type (used to coerce the key).
  final String type;
}

/// Lookup by `rowid` (tables without a primary key).
final class SqliteRowidLookup extends SqliteRowLookup {
  /// Creates a rowid lookup.
  const SqliteRowidLookup();
}

/// Resolves the row-lookup strategy for [table] (omp's
/// `resolveTableRowLookup`).
SqliteRowLookup resolveSqliteRowLookup(SqliteDatabase db, String table) {
  final pkColumns = [
    for (final row in _getTableInfoRows(db, table))
      if ((row['pk']! as int) > 0) row,
  ]..sort((a, b) => (a['pk']! as int).compareTo(b['pk']! as int));
  if (pkColumns.length == 1) {
    final column = pkColumns.first;
    return SqlitePkLookup(column['name']! as String, column['type']! as String);
  }
  if (pkColumns.length > 1) {
    throw StateError(
      "SQLite table '$table' has a composite primary key; use '?where=' "
      'instead',
    );
  }

  final schema = getSqliteTableSchema(db, table);
  if (RegExp(r'\bWITHOUT\s+ROWID\b', caseSensitive: false).hasMatch(schema)) {
    throw StateError(
      "SQLite table '$table' does not expose ROWID; use '?where=' instead",
    );
  }
  return const SqliteRowidLookup();
}

int _coerceIntegerKey(String key, String label) {
  final trimmed = key.trim();
  final parsed = int.tryParse(trimmed);
  if (parsed == null || !RegExp(r'^-?\d+$').hasMatch(trimmed)) {
    throw StateError("$label must be an integer; got '$key'");
  }
  return parsed;
}

Object _coerceLookupValue(String key, String type) {
  final normalizedType = type.trim().toUpperCase();
  if (normalizedType.contains('INT')) {
    return _coerceIntegerKey(key, "Primary key '$key'");
  }
  if (normalizedType.contains('REAL') ||
      normalizedType.contains('FLOA') ||
      normalizedType.contains('DOUB')) {
    final parsed = num.tryParse(key);
    if (parsed != null) return parsed;
  }
  return key;
}

/// Splits an `order` value into its column and direction parts (`column` or
/// `column:asc|desc`; the direction defaults to `asc`).
({String column, String direction}) _splitOrderSpec(String trimmed) {
  final separatorIndex = trimmed.lastIndexOf(':');
  final column = separatorIndex == -1
      ? trimmed
      : trimmed.substring(0, separatorIndex);
  final direction = separatorIndex == -1
      ? 'asc'
      : trimmed.substring(separatorIndex + 1).trim().toLowerCase();
  return (column: column, direction: direction);
}

String _resolveOrderClause(String? order, List<String> columns) {
  if (order == null) return '';
  final trimmed = order.trim();
  if (trimmed.isEmpty) return '';

  final (:column, :direction) = _splitOrderSpec(trimmed);
  if (!columns.contains(column)) {
    throw StateError("SQLite order column '$column' not found in table schema");
  }
  if (direction != 'asc' && direction != 'desc') {
    throw StateError(
      "SQLite order direction must be 'asc' or 'desc'; got '$direction'",
    );
  }
  return ' ORDER BY ${_quoteSqliteIdentifier(column)} ${direction.toUpperCase()}';
}

/// A paged table query result with the total row count for continuation
/// notes (omp's `queryRows` return shape).
final class SqliteTablePage {
  /// Creates a page.
  const SqliteTablePage({
    required this.columns,
    required this.rows,
    required this.totalCount,
  });

  /// Column names in schema order.
  final List<String> columns;

  /// The page rows.
  final List<Map<String, Object?>> rows;

  /// Total rows matching the (optional) WHERE clause.
  final int totalCount;
}

/// Runs a paged table query (omp's `queryRows`).
SqliteTablePage querySqliteRows(
  SqliteDatabase db,
  String table, {
  required int limit,
  required int offset,
  String? order,
  String? where,
}) {
  final columns = _getTableColumns(db, table);
  final validatedWhere = _validateWhereClause(where);
  final whereClause = validatedWhere != null ? ' WHERE $validatedWhere' : '';
  final orderClause = _resolveOrderClause(order, columns);
  final countSql =
      'SELECT COUNT(*) AS count FROM ${_quoteSqliteIdentifier(table)}$whereClause';
  final selectSql =
      'SELECT * FROM ${_quoteSqliteIdentifier(table)}$whereClause$orderClause'
      ' LIMIT ? OFFSET ?';
  final totalCount = (db.select(countSql).rows.first['count']! as int);
  if (db.parameterCount(selectSql) != 2) {
    throw StateError(
      'SQLite where clause changed the expected pagination parameters; use '
      'q=SELECT ... for raw SQL',
    );
  }
  final rows = db.select(selectSql, parameters: [limit, offset]).rows;
  return SqliteTablePage(columns: columns, rows: rows, totalCount: totalCount);
}

/// Looks a row up by primary key or rowid (omp's `getRowByKey` /
/// `getRowByRowId`). Returns null when no row matches.
Map<String, Object?>? getSqliteRow(
  SqliteDatabase db,
  String table,
  SqliteRowLookup lookup,
  String key,
) {
  _getTableMasterRow(db, table);
  final result = switch (lookup) {
    SqlitePkLookup(:final column, :final type) => db.select(
      'SELECT * FROM ${_quoteSqliteIdentifier(table)} WHERE '
      '${_quoteSqliteIdentifier(column)} = ? LIMIT 1',
      parameters: [_coerceLookupValue(key, type)],
    ),
    SqliteRowidLookup() => db.select(
      'SELECT * FROM ${_quoteSqliteIdentifier(table)} WHERE rowid = ? LIMIT 1',
      parameters: [_coerceIntegerKey(key, 'SQLite ROWID')],
    ),
  };
  return result.rows.isEmpty ? null : result.rows.first;
}

/// Runs a raw read-only query (omp's `executeReadQuery`): rejects bound
/// parameters and caps row collection at [maxSqliteRawQueryRows].
SqliteRows executeSqliteReadQuery(SqliteDatabase db, String sql) {
  if (db.parameterCount(sql) > 0) {
    throw StateError('SQLite raw queries do not support bound parameters');
  }
  return db.select(sql, maxRows: maxSqliteRawQueryRows);
}

// ---------------------------------------------------------------------------
// Rendering (omp's ASCII-table renderers)
// ---------------------------------------------------------------------------

/// Replaces tab characters with a single space (our `replaceTabs`).
String _replaceTabs(String value) => value.replaceAll('\t', ' ');

/// Truncates [value] to [width] characters, ending with an ellipsis when
/// cut (omp's `truncateToWidth`, measured in code units).
String truncateSqliteWidth(String value, int width) {
  if (value.length <= width) return value;
  if (width <= 1) return '…';
  return '${value.substring(0, width - 1)}…';
}

String _sanitizeCell(String value) {
  return _replaceTabs(value).replaceAll(RegExp(r'\r?\n'), r'\n');
}

/// Renders a SQLite value for a table cell (omp's
/// `stringifySqliteValue`).
String stringifySqliteValue(Object? value) {
  if (value == null) return 'NULL';
  if (value is String) return value;
  if (value is num || value is bool) return '$value';
  if (value is Uint8List) return '<BLOB ${formatToolSize(value.length)}>';
  return '$value';
}

String _padCell(String value, int width) {
  final truncated = truncateSqliteWidth(
    _sanitizeCell(value),
    width < _minColumnWidth ? _minColumnWidth : width,
  );
  if (truncated.length >= width) return truncated;
  return truncated.padRight(width);
}

/// Whether the ASCII layout fits at the floor (each column at
/// [_minColumnWidth]); when not, the renderer falls back to per-row vertical
/// blocks (omp's `tableFitsAtMinimum`, issue #3107).
bool _tableFitsAtMinimum(int columnCount) {
  return _minColumnWidth * columnCount +
          _columnSeparatorWidth * columnCount +
          _tableFrameWidth <=
      maxSqliteRenderWidth;
}

/// Vertical fallback used when a table has too many columns to fit
/// horizontally (>19 at the default 120-cell budget): each row becomes a
/// labelled block of `column: value` lines, mirroring `psql`'s expanded
/// display mode (omp's `buildVerticalBlocks`).
String _buildVerticalBlocks(
  List<String> columns,
  List<Map<String, Object?>> rows,
) {
  if (rows.isEmpty) return '(no rows)';
  var nameWidth = _minColumnWidth;
  for (final column in columns) {
    final width = _sanitizeCell(column).length;
    if (width > nameWidth) nameWidth = width;
  }
  nameWidth = nameWidth > maxSqliteColumnWidth
      ? maxSqliteColumnWidth
      : nameWidth;
  return [
    for (var index = 0; index < rows.length; index++)
      [
        '── Row ${index + 1} ──',
        for (final column in columns)
          truncateSqliteWidth(
            '${_padCell(column, nameWidth)}: '
            '${_sanitizeCell(stringifySqliteValue(rows[index][column]))}',
            maxSqliteRenderWidth,
          ),
      ].join('\n'),
  ].join('\n\n');
}

/// Initial per-column widths: the widest header/cell content, clamped to the
/// [_minColumnWidth]..[maxSqliteColumnWidth] band (omp's measuring pass).
List<int> _measureColumnWidths(
  List<String> columns,
  List<Map<String, Object?>> rows,
) {
  final widths = [
    for (final column in columns)
      _sanitizeCell(column).length.clamp(_minColumnWidth, maxSqliteColumnWidth),
  ];
  for (final row in rows) {
    for (var index = 0; index < columns.length; index++) {
      final cellWidth = _sanitizeCell(
        stringifySqliteValue(row[columns[index]]),
      ).length.clamp(_minColumnWidth, maxSqliteColumnWidth);
      if (cellWidth > widths[index]) widths[index] = cellWidth;
    }
  }
  return widths;
}

/// Shrinks [widths] in place, one cell off the widest column per pass, until
/// the whole table fits [maxSqliteRenderWidth] (omp's shrink loop).
void _shrinkWidthsToFit(List<int> widths, int columnCount) {
  final overhead = columnCount * _columnSeparatorWidth + _tableFrameWidth;
  var totalWidth = widths.fold(overhead, (sum, width) => sum + width);
  while (totalWidth > maxSqliteRenderWidth) {
    var widestIndex = -1;
    var widestWidth = _minColumnWidth;
    for (var index = 0; index < widths.length; index++) {
      if (widths[index] > widestWidth) {
        widestIndex = index;
        widestWidth = widths[index];
      }
    }
    if (widestIndex == -1) break;
    widths[widestIndex] = widths[widestIndex] - 1;
    if (widths[widestIndex] < _minColumnWidth) {
      widths[widestIndex] = _minColumnWidth;
    }
    totalWidth = widths.fold(overhead, (sum, width) => sum + width);
  }
}

/// Renders header, divider, and body rows at [widths], capping every line at
/// [maxSqliteRenderWidth] (omp's emit pass).
String _renderTableLines(
  List<String> columns,
  List<int> widths,
  List<Map<String, Object?>> rows,
) {
  final header =
      '| ${[for (var i = 0; i < columns.length; i++) _padCell(columns[i], widths[i])].join(' | ')} |';
  final divider =
      '| ${[for (final width in widths) '-' * width].join(' | ')} |';
  final lines = [header, divider];

  if (rows.isEmpty) {
    lines.add('(no rows)');
  } else {
    for (final row in rows) {
      final cells = [
        for (var i = 0; i < columns.length; i++)
          _padCell(stringifySqliteValue(row[columns[i]]), widths[i]),
      ];
      lines.add('| ${cells.join(' | ')} |');
    }
  }

  return lines
      .map(
        (line) => truncateSqliteWidth(_replaceTabs(line), maxSqliteRenderWidth),
      )
      .join('\n');
}

/// Renders rows as a width-capped ASCII table (omp's `buildAsciiTable`).
String buildSqliteAsciiTable(
  List<String> columns,
  List<Map<String, Object?>> rows,
) {
  if (columns.isEmpty) {
    return rows.isEmpty ? '(no rows)' : '(rows returned without named columns)';
  }
  if (!_tableFitsAtMinimum(columns.length)) {
    return _buildVerticalBlocks(columns, rows);
  }

  final widths = _measureColumnWidths(columns, rows);
  _shrinkWidthsToFit(widths, columns.length);
  return _renderTableLines(columns, widths, rows);
}

/// Renders the table list (omp's `renderTableList`).
String renderSqliteTableList(List<SqliteTableSummary> tables) {
  if (tables.isEmpty) return '(no tables)';
  return tables
      .map(
        (table) => truncateSqliteWidth(
          _replaceTabs(
            '${table.name} '
            '(${table.exact ? '${table.rows}' : '${table.rows}+'} rows)',
          ),
          maxSqliteRenderWidth,
        ),
      )
      .join('\n');
}

/// Renders a table schema plus sample rows (omp's `renderSchema`).
String renderSqliteSchema(String createSql, SqliteRows sampleRows) {
  final schemaLines = _replaceTabs(
    createSql,
  ).split('\n').map((line) => truncateSqliteWidth(line, maxSqliteRenderWidth));
  return [
    schemaLines.join('\n'),
    '',
    'Sample rows:',
    buildSqliteAsciiTable(sampleRows.columns, sampleRows.rows),
  ].join('\n');
}

/// Renders a single row as `column: value` lines (omp's `renderRow`).
String renderSqliteRow(Map<String, Object?> row) {
  if (row.isEmpty) return '(no columns)';
  return row.entries
      .map(
        (entry) => truncateSqliteWidth(
          _replaceTabs('${entry.key}: ${stringifySqliteValue(entry.value)}'),
          maxSqliteRenderWidth,
        ),
      )
      .join('\n');
}

/// Renders a paged table plus the continuation note when more rows remain
/// (omp's `renderTable`).
String renderSqliteTable(
  List<String> columns,
  List<Map<String, Object?>> rows, {
  required int totalCount,
  required int offset,
  required int limit,
  required String table,
}) {
  final parts = [buildSqliteAsciiTable(columns, rows)];
  final shown = totalCount < offset + rows.length
      ? totalCount
      : offset + rows.length;
  if (shown < totalCount) {
    final remaining = totalCount - shown;
    final nextOffset = offset + rows.length;
    parts.add(
      truncateSqliteWidth(
        _replaceTabs(
          '[$remaining more rows; append '
          ':$table?limit=$limit&offset=$nextOffset to the database path to '
          'continue]',
        ),
        maxSqliteRenderWidth,
      ),
    );
  }
  return parts.join('\n');
}
