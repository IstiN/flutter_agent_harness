// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of sandbox_builtins.dart: per-flag/per-argument helpers backing the
// builtin arg parsers. Same library, so private members resolve; top-level
// private functions here are library-private to their callers.

part of 'sandbox_builtins.dart';

/// Mutable parse state threaded through [SandboxBuiltins.parsePatchArgs]'s
/// per-argument helpers.
final class _PatchParseState {
  var strip = 0;
  String? patchFile;
  final positional = <String>[];
  var noMoreFlags = false;
  SandboxBuiltinResult? error;
}

/// Applies one `patch` argument at [args[i]], mutating [p]; returns the
/// number of extra operands consumed beyond the argument itself.
int _patchApplyArg(_PatchParseState p, List<String> args, int i) {
  final arg = args[i];
  if (p.noMoreFlags) return _patchPositionalArg(p, arg);
  if (arg == '--') {
    p.noMoreFlags = true;
    return 0;
  }
  if (!arg.startsWith('-') || arg == '-') {
    return _patchPositionalArg(p, arg);
  }
  return _patchDashFlagArg(p, args, i, arg);
}

/// Dispatches a `-`-prefixed `patch` argument to its flag handler, or
/// records the usage error for an unrecognized option.
int _patchDashFlagArg(
  _PatchParseState p,
  List<String> args,
  int i,
  String arg,
) {
  if (arg.startsWith('-p') || arg.startsWith('--strip')) {
    return _patchStripArg(p, args, i);
  }
  if (arg.startsWith('-i') || arg.startsWith('--input')) {
    return _patchInputArg(p, args, i);
  }
  p.error = SandboxBuiltins._error("patch: unrecognized option '$arg'\n", 2);
  return 0;
}

/// Applies a `-p`/`--strip` flag, recording the error result on failure.
int _patchStripArg(_PatchParseState p, List<String> args, int i) {
  final (value, error, extra) = SandboxBuiltins._patchStripFlag(args, i);
  if (error != null) {
    p.error = error;
    return 0;
  }
  p.strip = value!;
  return extra;
}

/// Applies an `-i`/`--input` flag, recording the error result on failure.
int _patchInputArg(_PatchParseState p, List<String> args, int i) {
  final (value, error, extra) = SandboxBuiltins._patchInputFlag(args, i);
  if (error != null) {
    p.error = error;
    return 0;
  }
  p.patchFile = value;
  return extra;
}

/// Records a `patch` positional operand (`[target] [patchfile]`); the
/// too-many-operands error is raised by the caller after the scan.
int _patchPositionalArg(_PatchParseState p, String arg) {
  p.positional.add(arg);
  return 0;
}

/// Applies one wget argument at [args[i]] to [curlArgs]; returns the
/// number of extra operands consumed (0 or 1). The checks run in the same
/// order as the original if-chain; the conditions are disjoint.
int _wgetApplyArg(List<String> curlArgs, List<String> args, int i) {
  final arg = args[i];
  final extra =
      _wgetOutputFlag(curlArgs, args, i, arg) ??
      _wgetQuietFlag(curlArgs, arg) ??
      _wgetNoCheckCertFlag(arg) ??
      _wgetWaitFlagConsumed(args, i, arg);
  if (extra != null) return extra;
  return _wgetPassthroughArg(curlArgs, arg);
}

/// Consumes wget's `-O f`/`--output-document=f`, translating to curl's
/// `-o`; returns null when [arg] is not one. A missing separate value
/// drops the flag entirely.
int? _wgetOutputFlag(
  List<String> curlArgs,
  List<String> args,
  int i,
  String arg,
) {
  if (arg == '-O' || arg == '--output-document') {
    if (i + 1 < args.length) {
      curlArgs.addAll(['-o', args[i + 1]]);
      return 1;
    }
    return 0;
  }
  if (arg.startsWith('--output-document=')) {
    curlArgs.addAll(['-o', arg.substring('--output-document='.length)]);
    return 0;
  }
  return null;
}

/// Consumes `-q`/`--quiet` (curl's `-s`); returns null when not matched.
int? _wgetQuietFlag(List<String> curlArgs, String arg) {
  if (arg == '-q' || arg == '--quiet') {
    curlArgs.add('-s');
    return 0;
  }
  return null;
}

/// Drops `--no-check-certificate` (TLS verification is not configurable
/// in the curl builtin); returns null when not matched.
int? _wgetNoCheckCertFlag(String arg) {
  if (arg == '--no-check-certificate') return 0;
  return null;
}

/// Whether [arg] is one of wget's wait flags (dropped, not curl flags —
/// `-w` means --write-out to curl).
bool _isWgetWaitFlag(String arg) =>
    arg == '-w' ||
    arg == '--wait' ||
    arg.startsWith('--wait=') ||
    arg.startsWith('--waitretry');

/// Whether wget's [arg] consumes the next operand as its seconds value.
bool _wgetWaitTakesValue(List<String> args, int i, String arg) =>
    (arg == '-w' || arg == '--wait' || arg == '--waitretry') &&
    i + 1 < args.length &&
    !args[i + 1].startsWith('-');

/// Drops a wget wait flag (with the separate seconds value of
/// `-w`/`--wait`/`--waitretry`); returns null when not a wait flag.
int? _wgetWaitFlagConsumed(List<String> args, int i, String arg) {
  if (!_isWgetWaitFlag(arg)) return null;
  return _wgetWaitTakesValue(args, i, arg) ? 1 : 0;
}

/// Everything else passes through to curl unchanged.
int _wgetPassthroughArg(List<String> curlArgs, String arg) {
  curlArgs.add(arg);
  return 0;
}

/// Builds curl's `-w` variable table (the supported `%{...}` set).
Map<String, String> _curlWriteOutVariables({
  required int statusCode,
  required Map<String, String> headers,
  required Uri url,
  required int bodyLength,
}) {
  return <String, String>{
    'http_code': '$statusCode',
    'size_download': '$bodyLength',
    'size_upload': '0',
    'content_type': headers['content-type'] ?? '',
    'url_effective': url.toString(),
    'response_code': '$statusCode',
  };
}

/// Consumes one `%`/`\` token at [i] of [template] into [out]; returns the
/// loop increment (characters consumed minus the loop's own `i++`), 0 and
/// the literal character when no escape applies.
int _curlWriteOutToken(
  StringBuffer out,
  String template,
  int i,
  Map<String, String> variables,
) {
  final c = template[i];
  if (c == r'\' && i + 1 < template.length) {
    _writeCurlWriteOutEscape(out, template[i + 1]);
    return 1;
  }
  if (c == '%' && i + 1 < template.length) {
    return _curlWriteOutPercentToken(out, template, i, variables);
  }
  out.write(c);
  return 0;
}

/// Handles the `%` forms (`%%`, `%{variable}`); returns the loop
/// increment, falling back to writing the literal `%` when no escape
/// shape applies (an unterminated `%{...`, like real curl).
int _curlWriteOutPercentToken(
  StringBuffer out,
  String template,
  int i,
  Map<String, String> variables,
) {
  final consumed = _curlWriteOutPercent(out, template, i, variables);
  if (consumed > 0) return consumed - 1;
  out.write('%');
  return 0;
}

/// Consumes `%%` or `%{name}` at [i]; returns the characters consumed
/// (0 when [i + 1] is not a recognized escape shape).
int _curlWriteOutPercent(
  StringBuffer out,
  String template,
  int i,
  Map<String, String> variables,
) {
  final n = template[i + 1];
  if (n == '%') {
    out.write('%');
    return 2;
  }
  if (n == '{') {
    final close = template.indexOf('}', i + 2);
    if (close != -1) {
      out.write(variables[template.substring(i + 2, close)] ?? '');
      return close - i + 1;
    }
  }
  return 0;
}

/// Writes the `\n`/`\r`/`\t` escape; any other escaped character passes
/// through verbatim (like real curl).
void _writeCurlWriteOutEscape(StringBuffer out, String n) {
  out.write(switch (n) {
    'n' => '\n',
    'r' => '\r',
    't' => '\t',
    final other => other,
  });
}

/// Appends one `@file` body segment's bytes to [segments]; returns the
/// error message when the read fails or the file is missing.
Future<String?> _curlBodyFileSegment(
  BytesBuilder segments,
  String path,
  SandboxBytesReader? readBinaryFile,
) async {
  final List<int>? data;
  try {
    data = await readBinaryFile?.call(path);
  } on Object catch (e) {
    return 'curl: $path: $e\n';
  }
  if (data == null) {
    return 'curl: $path: No such file or directory\n';
  }
  segments.add(data);
  return null;
}

/// Caps the request body at [SandboxBuiltins.maxCurlBodyBytes]; returns
/// `(bytes, null)` or `(null, error)`.
(List<int>?, String?) _curlBodyCapped(List<int> bytes) {
  if (bytes.length > SandboxBuiltins.maxCurlBodyBytes) {
    return (
      null,
      'curl: body exceeds the 1 MiB sandbox limit '
          '(${bytes.length} bytes); split the request or shrink the body\n',
    );
  }
  return (bytes, null);
}

/// Resolves the jq/yq input document: the named file's text, else the
/// piped [stdin]; the error result is non-null when the input is missing.
Future<(String?, SandboxBuiltinResult?)> _jsonFilterInput(
  String name,
  String? inputFile,
  String? stdin,
  SandboxTextReader readTextFile,
) async {
  final String? content;
  if (inputFile != null) {
    content = await readTextFile(inputFile);
    if (content == null) {
      return (
        null,
        SandboxBuiltins._error(
          '$name: $inputFile: No such file or directory\n',
          2,
        ),
      );
    }
  } else {
    content = stdin;
    if (content == null) {
      return (null, SandboxBuiltins._error('$name: missing input\n', 2));
    }
  }
  return (content, null);
}

/// Renders jq/yq results: raw strings verbatim under `-r`, else
/// JSON-encoded (indented unless `-c`), joined with newlines.
String _renderJsonFilterOutput(List<dynamic> results, JqArgs parsed) {
  final encoder = parsed.compact
      ? JsonEncoder()
      : const JsonEncoder.withIndent('  ');
  return results
      .map(
        (value) => parsed.rawOutput && value is String
            ? value
            : encoder.convert(value),
      )
      .join('\n');
}

/// Performs the DoH GET against [uri], converting a timeout into the
/// documented [FormatException].
Future<http.Response> _dohFetch(
  http.Client client,
  Uri uri,
  Duration? timeout,
) async {
  try {
    return await client
        .get(uri, headers: {'Accept': 'application/dns-json'})
        .timeout(timeout ?? const Duration(seconds: 15));
  } on TimeoutException {
    throw const FormatException(
      'DNS-over-HTTPS query to cloudflare-dns.com timed out',
    );
  }
}

/// Parses the `Answer` section into records, skipping malformed entries
/// (order preserved).
List<SandboxDnsRecord> _dohAnswers(Object? answerSection) {
  final answers = <SandboxDnsRecord>[];
  if (answerSection is List) {
    for (final record in answerSection) {
      final parsed = _dohRecord(record);
      if (parsed != null) answers.add(parsed);
    }
  }
  return answers;
}

/// One well-formed DoH answer record, or null when any required field has
/// the wrong type.
SandboxDnsRecord? _dohRecord(Object? record) {
  if (record is! Map<String, dynamic>) return null;
  final recordName = record['name'];
  final recordType = record['type'];
  final ttl = record['TTL'];
  final data = record['data'];
  if (recordName is! String || recordType is! int || data is! String) {
    return null;
  }
  return SandboxDnsRecord(
    name: recordName,
    type: recordType,
    ttl: _dohTtl(ttl),
    data: data,
  );
}

/// A DoH record TTL; non-numeric (or absent) reads as 0.
int _dohTtl(Object? ttl) => ttl is int ? ttl : 0;

/// Extracts the display name (`fn`) from an RDAP entity vCard, falling
/// back to the entity handle.
String? _rdapVcardName(Map<String, dynamic> entity) {
  final properties = _rdapVcardProperties(entity);
  if (properties == null) return null;
  for (final property in properties) {
    final value = _rdapVcardFnValue(property);
    if (value != null) return value;
  }
  return null;
}

/// An RDAP entity's vCard property list (element 1 of `vcardArray`), or
/// null when absent.
List? _rdapVcardProperties(Map<String, dynamic> entity) {
  final vcard = entity['vcardArray'];
  if (vcard is List && vcard.length > 1 && vcard[1] is List) {
    return vcard[1] as List;
  }
  return null;
}

/// The value of a vCard `fn` property (a cell list whose first cell is
/// `fn`), or null when [property] is not one or the value is empty.
String? _rdapVcardFnValue(Object? property) {
  if (!_isRdapVcardFnProperty(property)) return null;
  final value = (property as List)[3];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

/// Whether [property] is a vCard property cell list whose kind is `fn`.
bool _isRdapVcardFnProperty(Object? property) =>
    property is List && property.length > 3 && property[0] == 'fn';

/// An RDAP entity's `handle`, or null when absent or empty.
String? _rdapEntityHandle(Map<String, dynamic> entity) {
  final handle = entity['handle'];
  return handle is String && handle.isNotEmpty ? handle : null;
}

/// Whether [arg] is a decompress-family unpack flag (`-d`/`--decompress`/
/// `--uncompress`).
bool _isDecompressUnpackFlag(String arg) =>
    arg == '-d' || arg == '--decompress' || arg == '--uncompress';

/// Whether [arg] is a decompress-family keep flag (`-k`/`--keep`).
bool _isDecompressKeepFlag(String arg) => arg == '-k' || arg == '--keep';

/// Whether [arg] is a decompress-family stdout flag (`-c`/`--stdout`/
/// `--to-stdout`).
bool _isDecompressStdoutFlag(String arg) =>
    arg == '-c' || arg == '--stdout' || arg == '--to-stdout';

/// Decodes one decompressed payload and routes it to [stdout] (stdout
/// mode) or to the stripped-name output file (removing the source unless
/// keeping it); returns an error result, or null on success.
Future<SandboxBuiltinResult?> _decompressEmit(
  String name,
  List<int> read,
  String arg, {
  required String suffix,
  required List<int> Function(List<int> bytes) decode,
  required bool toStdout,
  required List<int> stdout,
  required SandboxBytesWriter writeBinaryFile,
  required bool keep,
  required SandboxFileRemover? removeFile,
}) async {
  final List<int> decoded;
  try {
    decoded = decode(read);
  } on Object {
    return SandboxBuiltins._error('$name: $arg: not in $name format\n', 1);
  }
  if (toStdout) {
    stdout.addAll(decoded);
    return null;
  }
  await writeBinaryFile(arg.substring(0, arg.length - suffix.length), decoded);
  final remover = removeFile;
  if (!keep && remover != null) await remover(arg);
  return null;
}

/// Applies one `base64` argument at [args[i]] to [b]; returns the number
/// of extra operands consumed (0 or 1). The caller stops on
/// [Base64Args.error].
int _base64ApplyArg(Base64Args b, List<String> args, int i) {
  final arg = args[i];
  if (arg == '-d' || arg == '--decode') {
    b.decode = true;
    return 0;
  }
  final wrap = SandboxBuiltins._base64WrapFlag(arg);
  if (wrap != null) {
    return _base64ApplyWrap(b, args, i, wrap);
  }
  return _base64OperandArg(b, arg);
}

/// Applies the wrap flag value; the bare `-w`/`--wrap` form consumes the
/// next operand, reported through the returned count.
int _base64ApplyWrap(
  Base64Args b,
  List<String> args,
  int i,
  (String?, bool) wrap,
) {
  final (columns, _) = wrap;
  if (columns == null) {
    if (i + 1 >= args.length) {
      b.error = SandboxBuiltins._error(
        "base64: option requires an argument -- 'w'\n",
        2,
      );
      return 0;
    }
    b.wrap = SandboxBuiltins._base64WrapValue(args[i + 1], b);
    return 1;
  }
  b.wrap = SandboxBuiltins._base64WrapValue(columns, b);
  return 0;
}

/// An input-file operand (the first one), an invalid-option error, or the
/// extra-operand error.
int _base64OperandArg(Base64Args b, String arg) {
  if (arg.startsWith('-') && arg != '-') {
    b.error = SandboxBuiltins._error(
      "base64: invalid option -- '${arg.substring(1)}'\n",
      2,
    );
    return 0;
  }
  if (b.inputFile == null) {
    b.inputFile = arg;
    return 0;
  }
  b.error = SandboxBuiltins._error("base64: extra operand '$arg'\n", 2);
  return 0;
}
