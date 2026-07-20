/// LSP protocol model types (a reduced port of oh-my-pi
/// `packages/coding-agent/src/lsp/types.ts`): positions, ranges, locations,
/// diagnostics, text edits, and workspace edits, plus `file://` URI
/// conversion helpers (`utils.ts`).
///
/// Only what the `lsp` tool's four ops (diagnostics / definition /
/// references / rename) need is modeled; everything else stays as raw JSON.
library;

/// Converts an absolute file path to a `file://` URI (omp's `fileToUri`).
///
/// Path segments are percent-encoded; Windows drive letters are mapped to
/// the `/C:/...` form. Paths are expected absolute with `/` separators (the
/// harness's [FileSystem] namespace).
String fileToUri(String path) {
  var p = path;
  // Windows drive: `C:\x` or `C:/x` → `/C:/x`.
  final drive = RegExp(r'^([a-zA-Z]):[\\/]').firstMatch(p);
  if (drive != null) {
    p = '/${drive.group(1)!.toUpperCase()}:${p.substring(2).replaceAll(r'\', '/')}';
  }
  if (!p.startsWith('/')) p = '/$p';
  final buffer = StringBuffer('file://');
  final segments = p.split('/');
  for (var i = 0; i < segments.length; i++) {
    if (i > 0) buffer.write('/');
    final segment = segments[i];
    // Keep the drive-letter colon (`C:`) readable per file-URI convention.
    if (i == 1 && RegExp(r'^[a-zA-Z]:$').hasMatch(segment)) {
      buffer.write(segment);
    } else {
      buffer.write(Uri.encodeComponent(segment));
    }
  }
  return buffer.toString();
}

/// Converts a `file://` URI back to a file path (omp's `uriToFile`).
///
/// Tolerates lax servers that send raw paths or unencoded `#`/`?`: anything
/// that does not parse cleanly falls back to a lenient manual conversion.
String uriToFile(String uri) {
  if (!uri.startsWith('file://')) return uri;
  var rest = uri.substring('file://'.length);
  // Drop a host component (`file://host/path`); keep the leading slash.
  if (!rest.startsWith('/')) {
    final slash = rest.indexOf('/');
    rest = slash == -1 ? '/' : rest.substring(slash);
  }
  String path;
  try {
    path = Uri.decodeComponent(rest);
  } on Object {
    path = rest;
  }
  // `/C:/...` → `C:/...`.
  if (RegExp(r'^/[a-zA-Z]:[\\/]').hasMatch(path)) {
    path = path.substring(1);
  }
  return path;
}

/// Renders [path] relative to [cwd] when it sits underneath it (omp's
/// `formatPathRelativeToCwd`, reduced to the common case).
String formatPathRelativeToCwd(String path, String cwd) {
  final prefix = cwd.endsWith('/') ? cwd : '$cwd/';
  if (path.startsWith(prefix)) return path.substring(prefix.length);
  return path;
}

/// LSP position (0-indexed line and character on the wire).
final class LspPosition {
  /// Creates an [LspPosition].
  const LspPosition({required this.line, required this.character});

  /// Parses a JSON `{"line": n, "character": n}` map.
  factory LspPosition.fromJson(Map<String, dynamic> json) => LspPosition(
    line: (json['line'] as num).toInt(),
    character: (json['character'] as num).toInt(),
  );

  /// 0-indexed line.
  final int line;

  /// 0-indexed character (UTF-16 code units per the LSP spec).
  final int character;

  /// JSON form for requests.
  Map<String, dynamic> toJson() => {'line': line, 'character': character};

  @override
  String toString() => '$line:$character';
}

/// LSP range.
final class LspRange {
  /// Creates an [LspRange].
  const LspRange({required this.start, required this.end});

  /// Parses a JSON `{"start": ..., "end": ...}` map.
  factory LspRange.fromJson(Map<String, dynamic> json) => LspRange(
    start: LspPosition.fromJson(json['start'] as Map<String, dynamic>),
    end: LspPosition.fromJson(json['end'] as Map<String, dynamic>),
  );

  /// Start position (inclusive).
  final LspPosition start;

  /// End position (exclusive).
  final LspPosition end;

  /// JSON form for requests.
  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  /// 1-indexed `startLine:startChar-endLine:endChar` for error messages
  /// (omp's `formatRange`).
  String format() =>
      '${start.line + 1}:${start.character + 1}-${end.line + 1}:${end.character + 1}';
}

/// LSP location: a range inside a document.
final class LspLocation {
  /// Creates an [LspLocation].
  const LspLocation({required this.uri, required this.range});

  /// Parses a JSON `{"uri": ..., "range": ...}` map.
  factory LspLocation.fromJson(Map<String, dynamic> json) => LspLocation(
    uri: json['uri'] as String,
    range: LspRange.fromJson(json['range'] as Map<String, dynamic>),
  );

  /// Document URI.
  final String uri;

  /// Range inside the document.
  final LspRange range;

  /// `file:line:col` with 1-indexed coordinates, path relative to [cwd]
  /// (omp's `formatLocation`).
  String format(String cwd) {
    final file = formatPathRelativeToCwd(uriToFile(uri), cwd);
    return '$file:${range.start.line + 1}:${range.start.character + 1}';
  }
}

/// Normalizes a `textDocument/definition`-family result: accepts `null`,
/// `Location`, `Location[]`, `LocationLink`, or `LocationLink[]` and returns
/// a flat location list (omp's `normalizeLocationResult`, reduced).
List<LspLocation> normalizeLocationResult(Object? result) {
  List<LspLocation> convert(Object? item) {
    if (item is! Map<String, dynamic>) return const [];
    // LocationLink: {targetUri, targetRange, targetSelectionRange?}.
    if (item.containsKey('targetUri')) {
      final selection = item['targetSelectionRange'] ?? item['targetRange'];
      if (selection is! Map<String, dynamic>) return const [];
      return [
        LspLocation(
          uri: item['targetUri'] as String,
          range: LspRange.fromJson(selection),
        ),
      ];
    }
    if (item['uri'] is String && item['range'] is Map<String, dynamic>) {
      return [LspLocation.fromJson(item)];
    }
    return const [];
  }

  if (result is List) {
    return [for (final item in result) ...convert(item)];
  }
  return convert(result);
}

/// LSP diagnostic severity (1=error, 2=warning, 3=information, 4=hint).
enum LspDiagnosticSeverity {
  /// Error.
  error(1, 'error'),

  /// Warning.
  warning(2, 'warning'),

  /// Information.
  info(3, 'info'),

  /// Hint.
  hint(4, 'hint');

  const LspDiagnosticSeverity(this.wireValue, this.label);

  /// The LSP wire value.
  final int wireValue;

  /// Human-readable label.
  final String label;

  /// Maps a wire value to a severity; unknown values map to [error].
  static LspDiagnosticSeverity fromWire(int? value) => switch (value) {
    2 => warning,
    3 => info,
    4 => hint,
    _ => error,
  };
}

/// LSP diagnostic.
final class LspDiagnostic {
  /// Creates an [LspDiagnostic].
  const LspDiagnostic({
    required this.range,
    required this.message,
    this.severity = LspDiagnosticSeverity.error,
    this.source,
    this.code,
  });

  /// Parses a JSON diagnostic map.
  factory LspDiagnostic.fromJson(Map<String, dynamic> json) => LspDiagnostic(
    range: LspRange.fromJson(json['range'] as Map<String, dynamic>),
    message: json['message'] as String? ?? '',
    severity: LspDiagnosticSeverity.fromWire(
      (json['severity'] as num?)?.toInt(),
    ),
    source: json['source'] as String?,
    code: json['code']?.toString(),
  );

  /// Where the diagnostic applies.
  final LspRange range;

  /// Human-readable message.
  final String message;

  /// Severity (defaults to error when the server omits it).
  final LspDiagnosticSeverity severity;

  /// Diagnostic source (e.g. the analyzer), when provided.
  final String? source;

  /// Diagnostic code, when provided.
  final String? code;
}

/// LSP text edit: replace [range] with [newText].
final class LspTextEdit {
  /// Creates an [LspTextEdit].
  const LspTextEdit({required this.range, required this.newText});

  /// Parses a JSON `{"range": ..., "newText": ...}` map.
  factory LspTextEdit.fromJson(Map<String, dynamic> json) => LspTextEdit(
    range: LspRange.fromJson(json['range'] as Map<String, dynamic>),
    newText: json['newText'] as String? ?? '',
  );

  /// The replaced range.
  final LspRange range;

  /// The replacement text.
  final String newText;
}

/// A parsed `WorkspaceEdit` (omp's `WorkspaceEdit`, reduced to text edits).
///
/// Both wire shapes are supported: the legacy `changes` map and
/// `documentChanges` entries carrying a `textDocument` + `edits`
/// (`TextDocumentEdit`). Resource operations (`create`/`rename`/`delete`
/// document changes) are collected in [skippedResourceOps] and reported but
/// not applied (omp's resource-op planning is not ported — the Dart analysis
/// server's rename answers carry text edits only).
final class LspWorkspaceEdit {
  /// Creates an [LspWorkspaceEdit].
  const LspWorkspaceEdit({
    required this.textEdits,
    this.documentVersions = const {},
    this.skippedResourceOps = 0,
  });

  /// Parses a JSON workspace edit map. Returns null for non-map input.
  static LspWorkspaceEdit? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final textEdits = <String, List<LspTextEdit>>{};
    final versions = <String, int?>{};
    var skipped = 0;

    void push(String uri, List<LspTextEdit> edits) {
      if (edits.isEmpty) return;
      (textEdits[uri] ??= []).addAll(edits);
    }

    final changes = json['changes'];
    if (changes is Map<String, dynamic>) {
      for (final entry in changes.entries) {
        final edits = entry.value;
        if (edits is! List) continue;
        push(entry.key, [
          for (final edit in edits)
            if (edit is Map<String, dynamic>) LspTextEdit.fromJson(edit),
        ]);
      }
    }

    final documentChanges = json['documentChanges'];
    if (documentChanges is List) {
      for (final change in documentChanges) {
        if (change is! Map<String, dynamic>) continue;
        final textDocument = change['textDocument'];
        final edits = change['edits'];
        if (textDocument is Map<String, dynamic> && edits is List) {
          final uri = textDocument['uri'] as String?;
          if (uri == null) continue;
          final version = (textDocument['version'] as num?)?.toInt();
          // The most specific (last) version wins for the guard.
          versions[uri] = version;
          push(uri, [
            for (final edit in edits)
              if (edit is Map<String, dynamic> &&
                  edit.containsKey('range') &&
                  edit.containsKey('newText'))
                LspTextEdit.fromJson(edit),
          ]);
        } else if (change['kind'] is String) {
          skipped++;
        }
      }
    }

    return LspWorkspaceEdit(
      textEdits: textEdits,
      documentVersions: versions,
      skippedResourceOps: skipped,
    );
  }

  /// Text edits keyed by document URI (omp's `flattenWorkspaceTextEdits`).
  final Map<String, List<LspTextEdit>> textEdits;

  /// The `textDocument.version` advertised per URI by `documentChanges`
  /// entries (null entry = server sent an unversioned identifier). Used by
  /// the version guard in `lsp_edits.dart`.
  final Map<String, int?> documentVersions;

  /// Number of resource operations (`create`/`rename`/`delete`) that were
  /// present but are not applied by this port.
  final int skippedResourceOps;

  /// Whether the edit carries no text edits at all.
  bool get isEmpty => textEdits.values.every((edits) => edits.isEmpty);
}
