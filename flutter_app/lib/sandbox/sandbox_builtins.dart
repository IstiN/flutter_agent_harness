// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:diffutil_dart/diffutil.dart' as diffutil;
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart' as yaml;

part 'sandbox_builtins_filetype.dart';
part 'sandbox_builtins_patch.dart';

/// Reads a text file from the shell's filesystem. Returns `null` when the
/// file does not exist. The path is the verbatim command argument; the
/// closure resolves it against the shell's current directory.
typedef SandboxTextReader = Future<String?> Function(String path);

/// Writes bytes to a file in the shell's filesystem, creating parent
/// directories as needed. The path is the verbatim command argument; the
/// closure resolves it against the shell's current directory.
typedef SandboxBytesWriter =
    Future<void> Function(String path, List<int> bytes);

/// Reads a binary file from the shell's filesystem. Returns `null` when the
/// file does not exist. The path is the verbatim command argument; the
/// closure resolves it against the shell's current directory.
typedef SandboxBytesReader = Future<List<int>?> Function(String path);

/// Removes a file from the shell's filesystem; a missing file is ignored.
/// The path is the verbatim command argument; the closure resolves it
/// against the shell's current directory.
typedef SandboxFileRemover = Future<void> Function(String path);

/// One immediate child of a directory, listed by [SandboxDirLister].
typedef SandboxDirEntry = ({String name, bool isDirectory});

/// Lists the immediate children of the directory at [path], or returns
/// `null` when [path] is not a directory (or does not exist). The path is
/// the verbatim command argument; the closure resolves it against the
/// shell's current directory.
typedef SandboxDirLister = Future<List<SandboxDirEntry>?> Function(String path);

/// Creates a directory (with parents) in the shell's filesystem. The path
/// is the verbatim command argument; the closure resolves it against the
/// shell's current directory.
typedef SandboxDirMaker = Future<void> Function(String path);

/// Parsed `curl`/`wget` command line; see [SandboxBuiltins.parseCurlArgs].
final class CurlArgs {
  CurlArgs();

  String? url;
  String method = 'GET';
  final Map<String, String> headers = {};
  final List<(String, bool)> dataArgs = []; // (value, expand @)
  String? outputFile;
  bool silent = false;
  bool followRedirects = false;
  bool explicitMethod = false;

}

/// Parsed `jq`/`yq` command line; see [SandboxBuiltins.parseJqArgs].
final class JqArgs {
  bool rawOutput = false;
  bool compact = false;
  final List<String> positional = [];
}

/// Parsed `diff` command line; see [SandboxBuiltins.parseDiffArgs].
final class DiffArgs {
  bool brief = false;
  bool newFile = false;
  int context = 3;
  final List<String> operands = [];
  SandboxBuiltinResult? error;
}

/// Parsed `base64` command line; see [SandboxBuiltins.parseBase64Args].
final class Base64Args {
  bool decode = false;
  int wrap = 76;
  String? inputFile;
  SandboxBuiltinResult? error;
}

/// Raw result of a single builtin command, in the same shape both shells
/// use for a pipeline stage.
final class SandboxBuiltinResult {
  /// Creates a result with raw stdout/stderr bytes and an exit code.
  const SandboxBuiltinResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  /// Standard output bytes.
  final List<int> stdout;

  /// Standard error bytes.
  final List<int> stderr;

  /// Process exit code.
  final int exitCode;
}

/// One DNS answer record, in the shape `dig` prints it.
final class SandboxDnsRecord {
  /// Creates a record with an owner [name], numeric [type] (1 = A,
  /// 28 = AAAA, ...), [ttl] in seconds, and the record [data].
  const SandboxDnsRecord({
    required this.name,
    required this.type,
    required this.ttl,
    required this.data,
  });

  /// Owner name of the record.
  final String name;

  /// Numeric record type (1 = A, 5 = CNAME, 12 = PTR, 28 = AAAA, ...).
  final int type;

  /// Time to live in seconds (0 when the resolver does not report one).
  final int ttl;

  /// Record payload (an address, host name, or type-specific text).
  final String data;
}

/// Result of a DNS query: the response status and the answer section.
final class SandboxDnsResult {
  /// Creates a result with an rcode [status], the [answers] section, and a
  /// human-readable [resolver] label for the status line.
  const SandboxDnsResult({
    required this.status,
    required this.answers,
    required this.resolver,
  });

  /// Response code: 0 = NOERROR, 2 = SERVFAIL, 3 = NXDOMAIN, ...
  final int status;

  /// The answer section records (empty on NXDOMAIN).
  final List<SandboxDnsRecord> answers;

  /// Resolver label shown in the output, e.g. `cloudflare-dns.com`.
  final String resolver;
}

/// Performs a DNS query for [name] and [type] (`A`, `AAAA`, `MX`, ...).
/// Throws on transport failure; an empty answer section is not an error.
typedef SandboxDnsQuery =
    Future<SandboxDnsResult> Function(String name, String type);

/// Exchanges a raw whois [query] with [server] over TCP port 43 and returns
/// the response text. Only implementable where raw TCP exists (`dart:io`).
typedef SandboxWhoisConnector =
    Future<String> Function(String query, String server);

/// Dart-native implementations of `curl`, `wget`, `jq`, `yq`, `diff`,
/// `patch`, `nslookup`, `dig`, `whois`, `tree`, `file`, `xz`/`bzip2`
/// (decompression), `base64`, and the `md5sum`/`sha*sum` checksums, shared
/// by the WASM shell (iOS/Android) and the in-memory web shell.
///
/// These are pure Dart (no `dart:io`) so they compile for the browser; each
/// shell injects its own filesystem access through [SandboxTextReader],
/// [SandboxBytesReader], [SandboxBytesWriter], [SandboxFileRemover], and
/// [SandboxDirLister], and HTTP goes through an injectable [http.Client]
/// so tests can use `MockClient` from `package:http/testing.dart`. The DNS
/// and whois transports are injectable too: the native shell resolves
/// A/AAAA/PTR via the `dart:io` system resolver and runs whois over raw TCP
/// port 43, while the defaults (used on the web) are DNS-over-HTTPS against
/// cloudflare-dns.com and RDAP over HTTPS via rdap.org.
final class SandboxBuiltins {
  /// Creates the builtins over the injected filesystem, HTTP client, and
  /// network-diagnostic transports.
  SandboxBuiltins({
    http.Client? httpClient,
    required this.readTextFile,
    required this.writeBinaryFile,
    this.readBinaryFile,
    this.listDirectory,
    this.removeFile,
    this.makeDirectory,
    this.dnsQuery,
    this.whoisConnector,
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  /// Injected DNS resolver; when null, [dohQuery] (cloudflare-dns.com) is
  /// used. See [SandboxDnsQuery].
  final SandboxDnsQuery? dnsQuery;

  /// Injected raw whois transport (TCP port 43); when null, `whois` falls
  /// back to RDAP over HTTPS via rdap.org. See [SandboxWhoisConnector].
  final SandboxWhoisConnector? whoisConnector;

  /// Injected text-file reader; see [SandboxTextReader].
  final SandboxTextReader readTextFile;

  /// Injected binary-file writer; see [SandboxBytesWriter].
  final SandboxBytesWriter writeBinaryFile;

  /// Injected binary-file reader (`file`, `xz`/`bzip2`, `base64`, checksum
  /// input); when null those commands report "not supported by this shell".
  /// See [SandboxBytesReader].
  final SandboxBytesReader? readBinaryFile;

  /// Injected directory lister for `tree`; when null `tree` reports
  /// "not supported by this shell". See [SandboxDirLister].
  final SandboxDirLister? listDirectory;

  /// Injected file remover used by `xz -d`/`bzip2 -d` to drop the original
  /// archive unless `-k` is given; when null the original is kept.
  final SandboxFileRemover? removeFile;

  /// Injected directory creator used by `unzip` to materialize archive
  /// directory entries; when null those entries are skipped (file writes
  /// still create their parents). See [SandboxDirMaker].
  final SandboxDirMaker? makeDirectory;

  /// Hard cap for a `-d`/`--data` request body (issue #337 E1): bigger
  /// payloads fail with a clean error instead of corrupting the request.
  static const int maxCurlBodyBytes = 1024 * 1024;

  static SandboxBuiltinResult _ok(
    List<int> stdout, [
    List<int> stderr = const [],
  ]) {
    return SandboxBuiltinResult(stdout: stdout, stderr: stderr, exitCode: 0);
  }

  static SandboxBuiltinResult _error(String message, int exitCode) {
    return SandboxBuiltinResult(
      stdout: const [],
      stderr: utf8.encode(message),
      exitCode: exitCode,
    );
  }

  // ---------------------------------------------------------------------------
  // curl / wget
  // ---------------------------------------------------------------------------

  /// The `--version`/`--help` short-circuits of the curl builtin; null
  /// when neither flag is present.
  static SandboxBuiltinResult? _curlPrelude(List<String> args) {
    if (args.contains('--version') || args.contains('-V')) {
      return _ok(
        utf8.encode(
          'curl 8.5.0 (Fa sandbox) Dart (Fa sandbox)\n'
          'Release-Date: 2026-01-01\n'
          'Protocols: http https\n'
          'Features: builtin\n',
        ),
      );
    }
    if (args.contains('--help') || args.contains('-h')) {
      return _ok(
        utf8.encode(
          'Usage: curl [options...] <url>\n'
          ' -X, --request <method>   HTTP method\n'
          ' -H, --header <header>    Pass custom header\n'
          ' -d, --data <data>        HTTP POST data; @file reads the file,\n'
          '                          multiple flags join with &, -d implies POST\n'
          '    --data-binary <data>  Like --data (bytes sent verbatim)\n'
          '    --data-raw <data>     Like --data but @ is literal (no file)\n'
          ' -o, --output <file>      Write to file instead of stdout\n'
          ' -s, --silent             Silent mode\n'
          ' -L, --location           Follow redirects\n'
          ' -V, --version            Show version\n',
        ),
      );
    }
    return null;
  }

  /// Builds the `package:http` request from parsed curl arguments: a data
  /// argument implies POST unless `-X` says otherwise (an explicit
  /// `-X GET -d ...` sends GET with a body).
  static http.Request _curlRequest(CurlArgs parsed, Uri uri, List<int>? bodyBytes) {
    final method = !parsed.explicitMethod && parsed.dataArgs.isNotEmpty
        ? 'POST'
        : parsed.method;
    final request = http.Request(method, uri);
    request.headers.addAll(parsed.headers);
    if (bodyBytes != null) request.bodyBytes = bodyBytes;
    request.followRedirects = parsed.followRedirects;
    return request;
  }

  Future<SandboxBuiltinResult> curl(
    List<String> args, {
    List<int>? stdinBytes,
    Duration? timeout,
  }) async {
    final prelude = _curlPrelude(args);
    if (prelude != null) return prelude;
    final parsed = parseCurlArgs(args);
    if (parsed.url == null) {
      return _error('curl: no URL specified\n', 2);
    }

    Uri uri;
    try {
      uri = Uri.parse(parsed.url!);
    } on FormatException {
      return _error('curl: invalid URL\n', 3);
    }

    final (bodyBytes, bodyError) = await _curlBody(
      parsed.dataArgs,
      stdinBytes: stdinBytes,
    );
    if (bodyError != null) return _error(bodyError, 26);

    final request = _curlRequest(parsed, uri, bodyBytes);

    final effectiveTimeout = timeout ?? const Duration(seconds: 30);
    final http.Response response;
    try {
      final streamedResponse = await _httpClient
          .send(request)
          .timeout(effectiveTimeout);
      response = await http.Response.fromStream(streamedResponse);
    } on TimeoutException {
      return _error('curl: (28) Operation timed out\n', 28);
    } on Object catch (e) {
      // Includes connection failures and browser CORS rejections.
      return _error('curl: (7) $e\n', 7);
    }

    final statusLine =
        'HTTP ${response.statusCode} '
        '${response.reasonPhrase ?? ""}\n';
    final stderr = parsed.silent ? const <int>[] : utf8.encode(statusLine);
    if (parsed.outputFile != null) {
      await writeBinaryFile(parsed.outputFile!, response.bodyBytes);
      return _ok(const [], stderr);
    }

    return _ok(response.bodyBytes, stderr);
  }
  /// Pure `wget` → `curl` argument translation: `-O f`/`--output-document=f`
  /// become `-o f` (a missing value drops the flag), `-q`/`--quiet` become
  /// `-s`, and `--no-check-certificate` is dropped (TLS verification is not
  /// configurable in the curl builtin). Everything else passes through.
  /// Table-tested; see [wget].
  static List<String> curlArgsFromWget(List<String> args) {
    final curlArgs = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-O' || arg == '--output-document') {
        if (i + 1 < args.length) {
          curlArgs.addAll(['-o', args[++i]]);
        }
      } else if (arg.startsWith('--output-document=')) {
        curlArgs.addAll(['-o', arg.substring('--output-document='.length)]);
      } else if (arg == '-q' || arg == '--quiet') {
        curlArgs.add('-s');
      } else if (arg == '--no-check-certificate') {
        // Ignored: TLS verification is not configurable in the curl builtin.
      } else {
        curlArgs.add(arg);
      }
    }
    return curlArgs;
  }

  /// Runs the `wget` builtin: a thin alias over [curl] translating
  /// `wget [-q] [-O file] URL` into the equivalent curl flags.
  Future<SandboxBuiltinResult> wget(
    List<String> args, {
    Duration? timeout,
  }) async {
    if (args.contains('--version') || args.contains('-V')) {
      return _ok(utf8.encode('GNU Wget 1.21.4 (fah-sandbox builtin)\n'));
    }
    return curl(curlArgsFromWget(args), timeout: timeout);
  }

  /// Splits an `-H value` argument into its `name: value` pair, or null
  /// when the colon is missing (or the name is empty) and the header is
  /// ignored like real curl does.
  static (String, String)? _curlHeaderPair(String header) {
    final idx = header.indexOf(':');
    if (idx > 0) {
      return (header.substring(0, idx).trim(), header.substring(idx + 1).trim());
    }
    return null;
  }

  /// Applies one `curl` flag that takes a value (`-X`, `-H`, `-d`/`--data*`,
  /// `-o`, `--url`). [next] is the argument after [arg] (null at the end);
  /// returns whether the value was consumed. A value flag at the end of the
  /// line is silently ignored, like real curl.
  static bool _curlValueFlag(CurlArgs c, String arg, String? next) {
    switch (arg) {
      case '-X' || '--request':
        if (next == null) return false;
        c.method = next;
        c.explicitMethod = true;
      case '-H' || '--header':
        if (next == null) return false;
        final pair = _curlHeaderPair(next);
        if (pair != null) c.headers[pair.$1] = pair.$2;
      case '-d' || '--data' || '--data-raw' || '--data-binary':
        if (next == null) return false;
        // `--data-raw` treats the value literally: no @file/@- expansion.
        c.dataArgs.add((next, arg != '--data-raw'));
      case '-o' || '--output':
        if (next == null) return false;
        c.outputFile = next;
      case '--url':
        if (next == null) return false;
        c.url = next;
      default:
        return false;
    }
    return true;
  }

  /// Pure `curl` argument parser: the common flag subset (`-X`, `-H`, `-d`,
  /// `-o`, `-s`, `-L`, `--url`, `--version`-less positionals). The last
  /// non-flag argument wins the URL. Table-tested; see [curl].
  static CurlArgs parseCurlArgs(List<String> args) {
    final c = CurlArgs();
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      final next = i + 1 < args.length ? args[i + 1] : null;
      if (arg == '-s' || arg == '--silent') {
        c.silent = true;
      } else if (arg == '-L' || arg == '--location') {
        c.followRedirects = true;
      } else if (_curlValueFlag(c, arg, next)) {
        i++;
      } else if (!arg.startsWith('-')) {
        c.url = arg;
      }
    }
    return c;
  }

  /// Resolves the POST body from the `-d/--data/--data-binary` arguments:
  /// `@file` reads the file's bytes, `-` reads stdin, plain values are sent
  /// verbatim, and multiple flags join with `&` (curl semantics). Returns
  /// `(null, error)` when a referenced file is missing or the body exceeds
  /// the sandbox size cap.
  Future<(List<int>?, String?)> _curlBody(
    List<(String, bool)> dataArgs, {
    List<int>? stdinBytes,
  }) async {
    if (dataArgs.isEmpty) return (null, null);
    final segments = BytesBuilder(copy: false);
    var first = true;
    for (final (value, expand) in dataArgs) {
      if (!first) segments.add(utf8.encode('&'));
      first = false;
      // Real curl reads the request body from stdin for `-d -` and `-d @-`.
      if (expand && (value == '-' || value == '@-') && stdinBytes != null) {
        segments.add(stdinBytes);
      } else if (expand && value.startsWith('@')) {
        final path = value.substring(1);
        final List<int>? data;
        try {
          data = await readBinaryFile?.call(path);
        } on Object catch (e) {
          return (null, 'curl: $path: $e\n');
        }
        if (data == null) {
          return (null, 'curl: $path: No such file or directory\n');
        }
        segments.add(data);
      } else {
        segments.add(utf8.encode(value));
      }
    }
    final bytes = segments.toBytes();
    if (bytes.length > maxCurlBodyBytes) {
      return (
        null,
        'curl: body exceeds the 1 MiB sandbox limit '
            '(${bytes.length} bytes); split the request or shrink the body\n',
      );
    }
    return (bytes, null);
  }

  // ---------------------------------------------------------------------------
  // jq / yq
  // ---------------------------------------------------------------------------

  /// Runs the `jq` builtin: `jq <filter> [file]`. Without a file argument the
  /// JSON document is read from [stdin] (piped input).
  Future<SandboxBuiltinResult> jq(List<String> args, {String? stdin}) {
    return _jsonFilter(
      'jq',
      args,
      stdin: stdin,
      parse: (content) {
        try {
          return (value: jsonDecode(content), error: null);
        } on FormatException catch (e) {
          return (value: null, error: 'jq: parse error: $e\n');
        }
      },
    );
  }

  /// Runs the `yq` builtin: like [jq] but parses YAML input into JSON first.
  Future<SandboxBuiltinResult> yq(List<String> args, {String? stdin}) {
    return _jsonFilter(
      'yq',
      args,
      stdin: stdin,
      parse: (content) {
        try {
          return (value: _yamlToJson(yaml.loadYaml(content)), error: null);
        } on yaml.YamlException catch (e) {
          return (value: null, error: 'yq: parse error: $e\n');
        }
      },
    );
  }

  Future<SandboxBuiltinResult> _jsonFilter(
    String name,
    List<String> args, {
    String? stdin,
    required ({Object? value, String? error}) Function(String content) parse,
  }) async {
    // Leading flags (`-r`, `--raw-output`, `-c`, `-e`, ...) are accepted but
    // only `-r`/`-c` change the output; see [parseJqArgs].
    final parsed = parseJqArgs(args);
    final (filter, inputFile) = (
      parsed.positional.isEmpty ? null : parsed.positional.first,
      parsed.positional.length > 1 ? parsed.positional[1] : null,
    );
    if (filter == null) {
      return _error('$name: missing filter\n', 2);
    }

    final String? content;
    if (inputFile != null) {
      content = await readTextFile(inputFile);
      if (content == null) {
        return _error('$name: $inputFile: No such file or directory\n', 2);
      }
    } else {
      content = stdin;
      if (content == null) {
        return _error('$name: missing input\n', 2);
      }
    }

    final doc = parse(content);
    if (doc.error != null) {
      return _error(doc.error!, 5);
    }

    final results = applyJqFilter(doc.value, filter);
    final encoder = parsed.compact
        ? JsonEncoder()
        : const JsonEncoder.withIndent('  ');
    final output = results
        .map(
          (value) => parsed.rawOutput && value is String
              ? value
              : encoder.convert(value),
        )
        .join('\n');
    return _ok(utf8.encode(output.isNotEmpty ? '$output\n' : ''));
  }


  /// Pure `jq`/`yq` argument pre-scan: leading flags (any `-x` before the
  /// first positional) are accepted; only `-r`/`--raw-output` and
  /// `-c`/`--compact-output` change the output. Everything after the first
  /// positional is positional (filter, then optional input file).
  /// Table-tested; see [_jsonFilter].
  static JqArgs parseJqArgs(List<String> args) {
    final j = JqArgs();
    for (final arg in args) {
      if (j.positional.isEmpty && arg.startsWith('-') && arg != '-') {
        if (arg == '-r' || arg == '--raw-output') j.rawOutput = true;
        if (arg == '-c' || arg == '--compact-output') j.compact = true;
        continue;
      }
      j.positional.add(arg);
    }
    return j;
  }

  // ---------------------------------------------------------------------------
  // diff / patch
  // ---------------------------------------------------------------------------

  /// Runs the `diff` builtin: compares two files line by line and prints a
  /// unified diff (`-u` is the default and only format; `-U n` changes the
  /// context width). `-q`/`--brief` only reports whether the files differ,
  /// and `-N`/`--new-file` treats a missing file as empty. An operand of `-`
  /// reads [stdin] (piped input). Exit codes follow GNU diff: 0 when the
  /// inputs are identical, 1 when they differ, 2 on error.
  Future<SandboxBuiltinResult> diff(List<String> args, {String? stdin}) async {
    final d = parseDiffArgs(args);
    if (d.error != null) return d.error!;
    final [oldOperand, newOperand] = d.operands;

    Future<String?> readOperand(String name) async {
      if (name == '-') return stdin ?? '';
      final read = await readTextFile(name);
      return read ?? (d.newFile ? '' : null);
    }

    final oldContent = await readOperand(oldOperand);
    if (oldContent == null) {
      return _error('diff: $oldOperand: No such file or directory\n', 2);
    }
    final newContent = await readOperand(newOperand);
    if (newContent == null) {
      return _error('diff: $newOperand: No such file or directory\n', 2);
    }

    final oldDoc = _LineDoc(oldContent);
    final newDoc = _LineDoc(newContent);
    final ops = _diffOps(oldDoc.tokens, newDoc.tokens);
    final differ = ops.any((op) => op.kind != _DiffOpKind.context);
    if (!differ) return _ok(const []);
    if (d.brief) {
      return SandboxBuiltinResult(
        stdout: utf8.encode('Files $oldOperand and $newOperand differ\n'),
        stderr: const [],
        exitCode: 1,
      );
    }
    return SandboxBuiltinResult(
      stdout: utf8.encode(
        _formatUnified(
          ops,
          oldDoc.tokens,
          newDoc.tokens,
          oldLabel: oldOperand,
          newLabel: newOperand,
          context: d.context,
        ),
      ),
      stderr: const [],
      exitCode: 1,
    );
  }

  /// Resolves the `-U` context width from the inline remainder (`-U5`) or
  /// the next argument (`-U 5`). Returns the parsed width (-1 when missing
  /// or not a non-negative integer), the raw value string for error
  /// messages, and the number of extra operands consumed.
  static (int, String, int) _diffContextValue(
    String inline,
    List<String> args,
    int i,
  ) {
    final (raw, extra) = inline.isNotEmpty
        ? (inline, 0)
        : (i + 1 < args.length ? args[i + 1] : '', i + 1 < args.length ? 1 : 0);
    final parsed = int.tryParse(raw);
    return (parsed == null || parsed < 0 ? -1 : parsed, raw, extra);
  }

  /// Applies one `diff` flag at `args[i]`; `--brief`, `--new-file` and
  /// `--unified` (the default) map directly, anything else is read as a
  /// bundled short-flag cluster (`-qNu5`), so the first character of an
  /// unknown long flag is reported exactly like GNU diff does. Returns the
  /// extra operands consumed (0 or 1) and sets [d.error] on the first
  /// invalid flag.
  static int _diffApplyFlag(DiffArgs d, List<String> args, int i, String arg) {
    switch (arg) {
      case '--brief':
        d.brief = true;
        return 0;
      case '--new-file':
        d.newFile = true;
        return 0;
      case '--unified':
        return 0; // Unified output is the default.
    }
    for (var j = 1; j < arg.length; j++) {
      switch (arg[j]) {
        case 'u':
          break; // Unified output is the default.
        case 'q':
          d.brief = true;
        case 'N':
          d.newFile = true;
        case 'U':
          final (value, raw, extra) = _diffContextValue(
            arg.substring(j + 1),
            args,
            i,
          );
          if (value < 0) {
            d.error = _error("diff: invalid context length '$raw'\n", 2);
            return extra;
          }
          d.context = value;
          return extra; // The rest of the arg is the number.
        default:
          d.error = _error("diff: invalid option -- '${arg[j]}'\n", 2);
          return 0;
      }
    }
    return 0;
  }

  /// Pure `diff` argument parser: `-q`/`--brief`, `-N`/`--new-file`,
  /// `-u`/`--unified`, `-U n` context width, `--`, and the two file
  /// operands (an operand of `-` means stdin). The first error wins and
  /// stops parsing; exactly two operands are required. Table-tested.
  static DiffArgs parseDiffArgs(List<String> args) {
    final d = DiffArgs();
    var noMoreFlags = false;
    var i = 0;
    while (i < args.length && d.error == null) {
      final arg = args[i];
      if (!noMoreFlags && arg == '--') {
        noMoreFlags = true;
      } else if (!noMoreFlags && arg.startsWith('-') && arg != '-') {
        i += _diffApplyFlag(d, args, i, arg);
      } else {
        d.operands.add(arg);
      }
      i++;
    }
    if (d.error == null && d.operands.length != 2) {
      d.error = _error('diff: expected two file operands\n', 2);
    }
    return d;
  }

  /// Runs the `patch` builtin: applies a unified diff read from [stdin]
  /// (piped input), from `-i file`/`--input=file`, or from a second
  /// positional argument, to files in the sandbox filesystem. `-p n` /
  /// `--strip=n` strips n leading path components from the file names in the
  /// diff headers (default 0); a positional target overrides those names
  /// entirely. Hunks are applied with offset search (no fuzz); a file is
  /// written only when all of its hunks apply. Exit codes follow GNU patch:
  /// 0 when everything applied, 1 when hunks failed, 2 on error.
  Future<SandboxBuiltinResult> patch(List<String> args, {String? stdin}) async {
    final (error, parsed) = parsePatchArgs(args);
    if (parsed == null) return error!;
    final (:strip, :patchFile, :target) = parsed;

    final String patchText;
    if (patchFile != null) {
      final read = await readTextFile(patchFile);
      if (read == null) {
        return _error('patch: $patchFile: No such file or directory\n', 2);
      }
      patchText = read;
    } else {
      patchText = stdin ?? '';
    }

    final files = _parsePatch(patchText);
    if (files == null) {
      return _error('patch: malformed patch input\n', 2);
    }
    if (files.isEmpty) {
      return _error('patch: no patch found in input\n', 2);
    }
    if (target != null && files.length > 1) {
      return _error(
        'patch: patch contains multiple files; omit the target operand\n',
        2,
      );
    }

    final out = StringBuffer();
    final err = StringBuffer();
    var failed = false;
    for (final file in files) {
      if (file.deletesFile) {
        return _error('patch: deleting files is not supported\n', 2);
      }
      final name = target ?? _stripPath(file.targetName, strip);
      if (name.isEmpty) {
        return _error('patch: empty file name after -p stripping\n', 2);
      }
      final _LineDoc doc;
      if (file.createsFile) {
        if (await readTextFile(name) != null) {
          err.write('patch: $name: already exists\n');
          failed = true;
          continue;
        }
        doc = _LineDoc('');
      } else {
        final content = await readTextFile(name);
        if (content == null) {
          return _error('patch: $name: No such file or directory\n', 2);
        }
        doc = _LineDoc(content);
      }
      final applied = _applyHunks(doc, file.hunks);
      if (applied.failures.isNotEmpty) {
        failed = true;
        for (final hunkNumber in applied.failures) {
          err.write('patch: Hunk #$hunkNumber FAILED in $name\n');
        }
        continue; // Never write a partially patched file.
      }
      out.write('patching file $name\n');
      await writeBinaryFile(
        name,
        utf8.encode(_joinLines(applied.lines, applied.trailingNewline)),
      );
    }
    return SandboxBuiltinResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: failed ? 1 : 0,
    );
  }

  /// Resolves a `--long=value` / `--long value` / `-s value` / `-svalue`
  /// flag (the shape shared by `--strip`/`-p` and `--input`/`-i`).
  /// Returns the value (null when the required argument is missing) plus
  /// the usage error; [optchar] is the short option letter the GNU-style
  /// "requires an argument" message names.
  static (String?, SandboxBuiltinResult?) _patchFlagValue(
    String arg,
    String? next, {
    required String long,
    required String short,
    required String optchar,
  }) {
    if (arg.startsWith('$long=')) {
      return (arg.substring(long.length + 1), null);
    }
    if (arg == long || arg == short) {
      if (next == null) {
        return (
          null,
          _error('patch: option requires an argument -- $optchar\n', 2),
        );
      }
      return (next, null);
    }
    if (arg.startsWith(short) && !arg.startsWith('--')) {
      return (arg.substring(short.length), null);
    }
    return (null, _error("patch: unrecognized option '$arg'\n", 2));
  }

  /// The `-p`/`--strip` flag: resolves its value and validates it as a
  /// non-negative integer. Returns the strip level, the usage error, and
  /// the extra operand consumed (1 only for the bare `-p`/`--strip` form).
  static (int?, SandboxBuiltinResult?, int) _patchStripFlag(
    List<String> args,
    int i,
  ) {
    final arg = args[i];
    final next = i + 1 < args.length ? args[i + 1] : null;
    final (value, error) = _patchFlagValue(
      arg,
      next,
      long: '--strip',
      short: '-p',
      optchar: 'p',
    );
    if (error != null) return (null, error, 0);
    final parsed = int.tryParse(value!);
    if (parsed == null || parsed < 0) {
      return (null, _error("patch: invalid strip count '$value'\n", 2), 0);
    }
    return (parsed, null, arg == '-p' || arg == '--strip' ? 1 : 0);
  }

  /// The `-i`/`--input` flag. Returns the patch file path, the usage
  /// error, and the extra operand consumed (1 only for the bare
  /// `-i`/`--input` form).
  static (String?, SandboxBuiltinResult?, int) _patchInputFlag(
    List<String> args,
    int i,
  ) {
    final arg = args[i];
    final next = i + 1 < args.length ? args[i + 1] : null;
    final (value, error) = _patchFlagValue(
      arg,
      next,
      long: '--input',
      short: '-i',
      optchar: 'i',
    );
    if (error != null) return (null, error, 0);
    return (value, null, arg == '-i' || arg == '--input' ? 1 : 0);
  }

  /// Pure `patch` argument parser: `-p n` / `-pn` / `--strip=n` /
  /// `--strip n`, `-i file` / `-ifile` / `--input=file` / `--input file`,
  /// `--`, and the positional `[target] [patchfile]` operands. Returns the
  /// usage-error result (exit code 2), or the parsed values with a null
  /// error. Table-tested; see [patch].
  static (
    SandboxBuiltinResult?,
    ({int strip, String? patchFile, String? target})?,
  )
  parsePatchArgs(List<String> args) {
    var strip = 0;
    String? patchFile;
    final positional = <String>[];
    var noMoreFlags = false;
    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      if (!noMoreFlags && arg == '--') {
        noMoreFlags = true;
      } else if (!noMoreFlags &&
          (arg.startsWith('-p') || arg.startsWith('--strip'))) {
        final (value, error, extra) = _patchStripFlag(args, i);
        if (error != null) return (error, null);
        strip = value!;
        i += extra;
      } else if (!noMoreFlags &&
          (arg.startsWith('-i') || arg.startsWith('--input'))) {
        final (value, error, extra) = _patchInputFlag(args, i);
        if (error != null) return (error, null);
        patchFile = value;
        i += extra;
      } else if (!noMoreFlags && arg.startsWith('-') && arg != '-') {
        return (_error("patch: unrecognized option '$arg'\n", 2), null);
      } else {
        positional.add(arg);
      }
      i++;
    }
    if (positional.length > 2) {
      return (_error('patch: too many file arguments\n', 2), null);
    }
    if (positional.length > 1) patchFile ??= positional[1];
    return (
      null,
      (
        strip: strip,
        patchFile: patchFile,
        target: positional.isNotEmpty ? positional[0] : null,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // nslookup / dig / whois
  // ---------------------------------------------------------------------------

  /// Runs the PTR branch of `nslookup <ipv4>`: reverse-resolves the
  /// address and prints `name = data` lines. Exit 1 on transport failure
  /// or NXDOMAIN.
  Future<SandboxBuiltinResult> _nslookupPtr(
    String host,
    String ptrName,
    Duration? timeout,
  ) async {
    final out = StringBuffer();
    final SandboxDnsResult result;
    try {
      result = await _dns(ptrName, 'PTR', timeout);
    } on Object catch (e) {
      return _error('nslookup: $e\n', 1);
    }
    if (result.answers.isEmpty) {
      return _error("server can't find $host: NXDOMAIN\n", 1);
    }
    out
      ..writeln('Server:  ${result.resolver}')
      ..writeln();
    for (final record in result.answers) {
      out.writeln('$ptrName name = ${record.data}');
    }
    return _ok(utf8.encode(out.toString()));
  }

  /// Runs the forward branch of `nslookup <host>`: queries A and AAAA and
  /// prints `Name:/Address:` blocks (CNAME records render as
  /// `canonical name =`). Exit 1 when nothing answers.
  Future<SandboxBuiltinResult> _nslookupHost(
    String host,
    Duration? timeout,
  ) async {
    final out = StringBuffer();
    final answers = <SandboxDnsRecord>[];
    var resolver = 'system resolver';
    var nxdomain = false;
    try {
      for (final type in const ['A', 'AAAA']) {
        final result = await _dns(host, type, timeout);
        resolver = result.resolver;
        nxdomain = nxdomain || result.status == 3;
        answers.addAll(result.answers);
      }
    } on Object catch (e) {
      return _error('nslookup: $e\n', 1);
    }
    if (answers.isEmpty) {
      return _error(
        "server can't find $host: ${nxdomain ? 'NXDOMAIN' : 'NOERROR'}\n",
        1,
      );
    }
    out
      ..writeln('Server:  $resolver')
      ..writeln();
    for (final record in answers) {
      if (record.type == 5) {
        out.writeln('${record.name} canonical name = ${record.data}');
      } else {
        out
          ..writeln('Name:    ${record.name}')
          ..writeln('Address: ${record.data}');
      }
    }
    return _ok(utf8.encode(out.toString()));
  }

  /// Runs the `nslookup` builtin: `nslookup <host|ipv4>`. A host name is
  /// resolved for A and AAAA records; an IPv4 literal triggers a PTR reverse
  /// lookup. Queries go through the injected [SandboxDnsQuery] (the `dart:io`
  /// system resolver on native), or DNS-over-HTTPS against
  /// cloudflare-dns.com when none is injected (the web default).
  /// Exit codes: 0 success, 1 lookup failure, 2 usage error.
  Future<SandboxBuiltinResult> nslookup(
    List<String> args, {
    Duration? timeout,
  }) async {
    if (args.length != 1) {
      return _error('usage: nslookup <host>\n', 2);
    }
    final host = args.first;
    final ptrName = ipv4PtrName(host);
    if (ptrName != null) return _nslookupPtr(host, ptrName, timeout);
    return _nslookupHost(host, timeout);
  }

  /// Record types accepted by the `dig` builtin.
  static const _digTypes = {
    'A',
    'AAAA',
    'CNAME',
    'MX',
    'NS',
    'PTR',
    'SOA',
    'SRV',
    'TXT',
  };

  /// Runs the `dig` builtin: `dig [-x] <host> [TYPE]` with compact output —
  /// a status line, the answer section, and the resolver (full BIND output
  /// is not reproduced). TYPE defaults to A; `-x` turns an IPv4 literal into
  /// a PTR query. On native, A/AAAA/PTR go through the `dart:io` system
  /// resolver and the other types through DNS-over-HTTPS; on the web
  /// everything uses DNS-over-HTTPS. Exit codes: 0 when the query completed
  /// (any status, including NXDOMAIN, like real dig), 1 on transport
  /// failure, 2 on usage error. Note: on native a failed A/AAAA system
  /// lookup surfaces as a transport failure (exit 1) because the OS
  /// resolver does not expose the rcode — an exact NXDOMAIN status line is
  /// only available through DNS-over-HTTPS.
  /// Pure `dig` argument parser: `-x` (reverse), one host operand, and an
  /// optional record TYPE (defaults to A; a second TYPE is a usage error).
  /// `-x` converts an IPv4 literal to its PTR name. Table-tested; see
  /// [dig].
  static ({bool reverse, String? name, String type, SandboxBuiltinResult? error})
  parseDigArgs(List<String> args) {
    var reverse = false;
    String? name;
    var type = 'A';
    for (final arg in args) {
      if (arg == '-x') {
        reverse = true;
      } else if (arg.startsWith('-')) {
        return (
          reverse: reverse,
          name: name,
          type: type,
          error: _error("dig: unknown option '$arg'\n", 2),
        );
      } else if (name == null) {
        name = arg;
      } else {
        final upper = arg.toUpperCase();
        if (!_digTypes.contains(upper)) {
          return (
            reverse: reverse,
            name: name,
            type: type,
            error: _error("dig: unknown query type '$arg'\n", 2),
          );
        }
        if (type != 'A') {
          return (
            reverse: reverse,
            name: name,
            type: type,
            error: _error('usage: dig [-x] <host> [TYPE]\n', 2),
          );
        }
        type = upper;
      }
    }
    if (name == null) {
      return (
        reverse: reverse,
        name: name,
        type: type,
        error: _error('usage: dig [-x] <host> [TYPE]\n', 2),
      );
    }
    if (reverse) {
      final ptrName = ipv4PtrName(name);
      if (ptrName == null) {
        return (
          reverse: reverse,
          name: name,
          type: type,
          error: _error('dig: -x expects an IPv4 address\n', 2),
        );
      }
      name = ptrName;
      type = 'PTR';
    }
    return (reverse: reverse, name: name, type: type, error: null);
  }

  /// Runs the `dig` builtin: `dig [-x] <host> [TYPE]` with compact output —
  /// a status line, the answer section, and the resolver (full BIND output
  /// is not reproduced). TYPE defaults to A; `-x` turns an IPv4 literal into
  /// a PTR query. On native, A/AAAA/PTR go through the `dart:io` system
  /// resolver and the other types through DNS-over-HTTPS; on the web
  /// everything uses DNS-over-HTTPS. Exit codes: 0 when the query completed
  /// (any status, including NXDOMAIN, like real dig), 1 on transport
  /// failure, 2 on usage error. Note: on native a failed A/AAAA system
  /// lookup surfaces as a transport failure (exit 1) because the OS
  /// resolver does not expose the rcode — an exact NXDOMAIN status line is
  /// only available through DNS-over-HTTPS.
  Future<SandboxBuiltinResult> dig(
    List<String> args, {
    Duration? timeout,
  }) async {
    final d = parseDigArgs(args);
    if (d.error != null) return d.error!;
    final name = d.name!;
    final type = d.type;

    final SandboxDnsResult result;
    try {
      result = await _dns(name, type, timeout);
    } on Object catch (e) {
      return _error(';; communications error: $e\n', 1);
    }
    final out = StringBuffer()
      ..writeln(';; status: ${_dnsStatusName(result.status)}')
      ..writeln(';; SERVER: ${result.resolver}');
    if (result.answers.isNotEmpty) {
      out
        ..writeln()
        ..writeln(';; ANSWER SECTION:');
      for (final record in result.answers) {
        out.writeln(
          '${record.name}\t${record.ttl}\tIN\t'
          '${_dnsTypeName(record.type)}\t${record.data}',
        );
      }
    }
    return _ok(utf8.encode(out.toString()));
  }

  /// Runs the `whois` builtin: `whois <domain|ip>`. With an injected
  /// [SandboxWhoisConnector] (`dart:io`, TCP port 43) the query goes to
  /// whois.iana.org (the TLD for a domain, the literal for an IP) and
  /// follows one `refer:`/`whois:` referral to the authoritative server,
  /// printing the authoritative response (or the IANA response when there
  /// is no referral or the referred server is unreachable). Without a
  /// connector (the web default), whois falls back to RDAP over HTTPS via
  /// rdap.org and prints a compact summary of the JSON record. Exit codes:
  /// 0 success, 1 lookup failure, 2 usage error.
  Future<SandboxBuiltinResult> whois(
    List<String> args, {
    Duration? timeout,
  }) async {
    if (args.length != 1) {
      return _error('usage: whois <domain|ip>\n', 2);
    }
    final target = args.first;
    final connector = whoisConnector;
    if (connector != null) return _whoisTcp(target, connector);
    return _whoisRdap(target, timeout);
  }

  Future<SandboxBuiltinResult> _whoisTcp(
    String target,
    SandboxWhoisConnector connector,
  ) async {
    // IANA answers TLD lookups: a domain target is reduced to its last
    // label; IP literals and bare TLDs go verbatim.
    final isIp = ipv4PtrName(target) != null || target.contains(':');
    final ianaQuery = isIp || !target.contains('.')
        ? target
        : target.split('.').last;
    final String iana;
    try {
      iana = await connector(ianaQuery, 'whois.iana.org');
    } on Object catch (e) {
      return _error('whois: whois.iana.org: $e\n', 1);
    }
    final refer = _whoisReferral(iana);
    if (refer == null) return _ok(utf8.encode(_terminated(iana)));
    try {
      final authoritative = await connector(target, refer);
      if (authoritative.isNotEmpty) {
        return _ok(utf8.encode(_terminated(authoritative)));
      }
    } on Object {
      // The referral target is unreachable; the IANA response still carries
      // the TLD info, so report success with what we have.
    }
    return _ok(utf8.encode(_terminated(iana)));
  }

  Future<SandboxBuiltinResult> _whoisRdap(
    String target,
    Duration? timeout,
  ) async {
    final isIp = ipv4PtrName(target) != null || target.contains(':');
    final uri = Uri.parse('https://rdap.org/${isIp ? 'ip' : 'domain'}/$target');
    final http.Response response;
    try {
      response = await _httpClient
          .get(uri, headers: {'Accept': 'application/rdap+json'})
          .timeout(timeout ?? const Duration(seconds: 30));
    } on TimeoutException {
      return _error('whois: rdap.org: operation timed out\n', 1);
    } on Object catch (e) {
      // Includes connection failures and browser CORS rejections.
      return _error('whois: rdap.org: $e\n', 1);
    }
    if (response.statusCode == 404) {
      return _error('whois: $target: not found\n', 1);
    }
    if (response.statusCode != 200) {
      return _error('whois: rdap.org: HTTP ${response.statusCode}\n', 1);
    }
    final Object? doc;
    try {
      doc = jsonDecode(response.body);
    } on FormatException {
      return _error('whois: rdap.org: malformed JSON response\n', 1);
    }
    return _ok(utf8.encode(_rdapSummary(doc)));
  }

  Future<SandboxDnsResult> _dns(String name, String type, Duration? timeout) {
    final query = dnsQuery;
    if (query != null) return query(name, type);
    return dohQuery(_httpClient, name, type, timeout: timeout);
  }

  /// Queries DNS over HTTPS against cloudflare-dns.com (the
  /// `application/dns-json` API) using [client]. This is the default
  /// resolver when no [SandboxDnsQuery] is injected (the web case); native
  /// shells also fall back to it for the record types
  /// `InternetAddress.lookup` cannot answer. Throws on transport failure.
  static Future<SandboxDnsResult> dohQuery(
    http.Client client,
    String name,
    String type, {
    Duration? timeout,
  }) async {
    final uri = Uri.https('cloudflare-dns.com', '/dns-query', {
      'name': name,
      'type': type,
    });
    final http.Response response;
    try {
      response = await client
          .get(uri, headers: {'Accept': 'application/dns-json'})
          .timeout(timeout ?? const Duration(seconds: 15));
    } on TimeoutException {
      throw const FormatException(
        'DNS-over-HTTPS query to cloudflare-dns.com timed out',
      );
    }
    if (response.statusCode != 200) {
      throw FormatException(
        'DNS-over-HTTPS query failed: HTTP ${response.statusCode}',
      );
    }
    final Object? doc = jsonDecode(response.body);
    if (doc is! Map<String, dynamic>) {
      throw const FormatException('malformed DNS-over-HTTPS response');
    }
    final answers = <SandboxDnsRecord>[];
    final answerSection = doc['Answer'];
    if (answerSection is List) {
      for (final record in answerSection) {
        if (record is! Map<String, dynamic>) continue;
        final recordName = record['name'];
        final recordType = record['type'];
        final ttl = record['TTL'];
        final data = record['data'];
        if (recordName is! String || recordType is! int || data is! String) {
          continue;
        }
        answers.add(
          SandboxDnsRecord(
            name: recordName,
            type: recordType,
            ttl: ttl is int ? ttl : 0,
            data: data,
          ),
        );
      }
    }
    final status = doc['Status'];
    return SandboxDnsResult(
      status: status is int ? status : 0,
      answers: answers,
      resolver: 'cloudflare-dns.com',
    );
  }

  /// Returns the `in-addr.arpa` PTR name for an IPv4 literal like `1.2.3.4`,
  /// or null when [host] is not a dotted-quad address.
  static String? ipv4PtrName(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value > 255 || part != '$value') return null;
    }
    return '${parts.reversed.join('.')}.in-addr.arpa';
  }

  /// Inverse of [ipv4PtrName]: the IPv4 literal of an `in-addr.arpa` name,
  /// or null when [ptrName] is not one. Used by the `dart:io` resolver to
  /// feed `InternetAddress.reverse`.
  static String? ipv4FromPtrName(String ptrName) {
    const suffix = '.in-addr.arpa';
    if (!ptrName.endsWith(suffix)) return null;
    final literal = ptrName
        .substring(0, ptrName.length - suffix.length)
        .split('.')
        .reversed
        .join('.');
    return ipv4PtrName(literal) != null ? literal : null;
  }

  /// Extracts the authoritative whois server from an IANA response's
  /// `refer:`/`whois:` line, or null when there is none.
  static String? _whoisReferral(String text) {
    for (final line in text.split('\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase();
      if (key == 'refer' || key == 'whois') {
        final server = line.substring(colon + 1).trim();
        if (server.isNotEmpty) return server;
      }
    }
    return null;
  }

  /// Writes the domain-specific or network-specific header fields.
  static void _rdapHeaderFields(
    Map<String, dynamic> doc,
    bool isDomain,
    void Function(String label, Object? value) field,
  ) {
    if (isDomain) {
      field('Domain Name', doc['ldhName']);
      field('Registry Domain ID', doc['handle']);
    } else {
      field('NetName', doc['name']);
      field('NetHandle', doc['handle']);
    }
  }

  /// Writes the `NetRange` line for network records.
  static void _rdapNetRange(Map<String, dynamic> doc, StringBuffer out) {
    final start = doc['startAddress'];
    final end = doc['endAddress'];
    if (start is String && end is String) {
      out.writeln('NetRange: $start - $end');
    }
  }

  /// Writes one line per status value (`Domain Status` for domains).
  static void _rdapStatusLines(
    Map<String, dynamic> doc,
    bool isDomain,
    void Function(String label, Object? value) field,
  ) {
    final status = doc['status'];
    if (status is List) {
      for (final value in status) {
        field(isDomain ? 'Domain Status' : 'Status', value);
      }
    }
  }

  /// Writes the registrar line (with the IANA ID when present) or one
  /// line per entity role.
  static void _rdapEntityLines(List<Object?> entities, StringBuffer out) {
    for (final entity in entities) {
      if (entity is! Map<String, dynamic>) continue;
      final name = _rdapEntityName(entity);
      final roles = entity['roles'];
      if (name == null || roles is! List) continue;
      if (roles.contains('registrar')) {
        var line = name;
        final publicIds = entity['publicIds'];
        if (publicIds is List && publicIds.isNotEmpty) {
          final id = publicIds.first;
          if (id is Map<String, dynamic>) {
            line += ' (IANA ID: ${id['identifier']})';
          }
        }
        out.writeln('Registrar: $line');
      } else {
        for (final role in roles) {
          out.writeln('${_rdapRoleName(role)}: $name');
        }
      }
    }
  }

  /// Writes one `Label: date` line per RDAP event.
  static void _rdapEventLines(List<Object?> events, StringBuffer out) {
    for (final event in events) {
      if (event is! Map<String, dynamic>) continue;
      final action = event['eventAction'];
      final date = event['eventDate'];
      if (action is! String || date is! String) continue;
      out.writeln('${_rdapEventName(action)}: $date');
    }
  }

  /// Writes one `Name Server:` line per RDAP nameserver entry.
  static void _rdapNameserverLines(
    List<Object?> nameservers,
    void Function(String label, Object? value) field,
  ) {
    for (final ns in nameservers) {
      if (ns is Map<String, dynamic>) field('Name Server', ns['ldhName']);
    }
  }

  /// Renders an RDAP JSON document as a compact human summary (the
  /// web `whois` fallback); unrecognized shapes fall back to pretty-printed
  /// JSON. Table-tested through [whois].
  static String _rdapSummary(Object? doc) {
    if (doc is! Map<String, dynamic>) {
      return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
    }
    final out = StringBuffer();
    final isDomain = doc['objectClassName'] == 'domain';
    void field(String label, Object? value) {
      if (value is String && value.isNotEmpty) {
        out.writeln('$label: $value');
      }
    }

    _rdapHeaderFields(doc, isDomain, field);
    if (!isDomain) _rdapNetRange(doc, out);
    field('Country', doc['country']);
    _rdapStatusLines(doc, isDomain, field);
    final entities = doc['entities'];
    if (entities is List) _rdapEntityLines(entities, out);
    final events = doc['events'];
    if (events is List) _rdapEventLines(events, out);
    final nameservers = doc['nameservers'];
    if (nameservers is List) _rdapNameserverLines(nameservers, field);
    if (out.isNotEmpty) return out.toString();
    return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
  }
  /// Extracts the display name (`fn`) from an RDAP entity's vCard, falling
  /// back to the entity handle.
  static String? _rdapEntityName(Map<String, dynamic> entity) {
    final vcard = entity['vcardArray'];
    if (vcard is List && vcard.length > 1 && vcard[1] is List) {
      for (final property in vcard[1] as List) {
        if (property is List && property.length > 3 && property[0] == 'fn') {
          final value = property[3];
          if (value is String && value.isNotEmpty) return value;
        }
      }
    }
    final handle = entity['handle'];
    return handle is String && handle.isNotEmpty ? handle : null;
  }

  static String _rdapRoleName(Object? role) {
    const names = {
      'registrant': 'Registrant',
      'administrative': 'Admin',
      'technical': 'Tech',
      'abuse': 'Abuse Contact',
      'billing': 'Billing',
      'sponsor': 'Sponsor',
    };
    return names[role] ?? '$role';
  }

  static String _rdapEventName(String action) {
    const names = {
      'registration': 'Creation Date',
      'reregistration': 'Updated Date',
      'last changed': 'Updated Date',
      'expiration': 'Registry Expiry Date',
      'deletion': 'Deletion Date',
      'reinstantiation': 'Reinstantiation Date',
      'transfer': 'Transfer Date',
      'locked': 'Locked Date',
      'unlocked': 'Unlocked Date',
      'last update of RDAP database': 'RDAP Updated Date',
    };
    return names[action] ?? '$action Date';
  }

  static String _terminated(String text) {
    return text.endsWith('\n') ? text : '$text\n';
  }

  /// DNS record type names by number, for dig-style output.
  static const _dnsTypeNames = {
    1: 'A',
    2: 'NS',
    5: 'CNAME',
    6: 'SOA',
    12: 'PTR',
    15: 'MX',
    16: 'TXT',
    28: 'AAAA',
    33: 'SRV',
    255: 'ANY',
  };

  static String _dnsTypeName(int type) => _dnsTypeNames[type] ?? 'TYPE$type';

  static String _dnsStatusName(int status) {
    const names = {
      0: 'NOERROR',
      1: 'FORMERR',
      2: 'SERVFAIL',
      3: 'NXDOMAIN',
      4: 'NOTIMP',
      5: 'REFUSED',
    };
    return names[status] ?? 'STATUS$status';
  }

  dynamic _yamlToJson(dynamic value) {
    if (value is yaml.YamlMap) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _yamlToJson(entry.value),
      };
    }
    if (value is yaml.YamlList) {
      return value.map(_yamlToJson).toList();
    }
    return value;
  }

  /// Applies one terminal jq filter word: `length` of a list/string/map or
  /// the `keys` of a map; anything else (including scalars without a
  /// length) produces no output, like jq's `empty`.
  static List<dynamic>? _jqTerminal(String part, dynamic current) {
    if (part == 'length') {
      if (current is List || current is String || current is Map) {
        return [(current as dynamic).length as Object];
      }
      return const [];
    }
    if (part == 'keys') {
      if (current is Map) return [current.keys.toList()];
      return const [];
    }
    return null;
  }

  /// Expands `.[]` over a list, applying the remaining [rest] filter to
  /// every element; a non-list under `.[]` produces nothing.
  static List<dynamic> _jqExpand(List<dynamic> current, String rest) {
    return current
        .expand((e) => applyJqFilter(e, rest.isEmpty ? '.' : '.$rest'))
        .toList();
  }

  /// Evaluates the jq filter subset against [input]: `.`, `length`, `keys`,
  /// dotted paths (`.a.b`), and `[]` iteration (`.a[].b`). Unknown filters
  /// yield empty output. Table-tested; see [jq].
  static List<dynamic> applyJqFilter(dynamic input, String filter) {
    if (filter == '.') return [input];
    final terminal = _jqTerminal(filter, input);
    if (terminal != null) return terminal;

    final parts = filter.split('.').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return [input];

    dynamic current = input;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part == '[]') {
        if (current is List) {
          return _jqExpand(current, parts.sublist(i + 1).join('.'));
        }
        return const [];
      }
      if (i == parts.length - 1) {
        final terminal = _jqTerminal(part, current);
        if (terminal != null) return terminal;
      }
      if (current is Map) {
        current = current[part];
      } else {
        return const [];
      }
    }
    return [current];
  }

  // ---------------------------------------------------------------------------
  // tree
  // ---------------------------------------------------------------------------

  /// Resolves the `-L`/`-Ln` depth flag: the value comes inline (`-L2`) or
  /// from the next argument (`-L 2`). Returns the parsed level (null when
  /// invalid), the extra operand consumed, and the usage error.
  static (int?, int, SandboxBuiltinResult?) _treeDepthFlag(
    String arg,
    List<String> args,
    int i,
  ) {
    if (arg == '-L') {
      if (i + 1 >= args.length) {
        return (null, 0, _error('tree: Missing argument to -L option.\n', 2));
      }
      final depth = int.tryParse(args[i + 1]);
      if (depth == null || depth < 1) {
        return (
          null,
          1,
          _error('tree: Invalid level, must be greater than 0.\n', 2),
        );
      }
      return (depth, 1, null);
  }
    final depth = int.tryParse(arg.substring(2));
    if (depth == null || depth < 1) {
      return (null, 0, _error('tree: Invalid level, must be greater than 0.\n', 2));
    }
    return (depth, 0, null);
  }

  /// Pure `tree` argument parser: `-a`, `-L n`/`-Ln`, one optional root,
  /// `--help`. [early] carries the `--help` output or the usage error and
  /// ends the command. Table-tested; see [tree].
  static ({bool showHidden, int? maxDepth, String? root, SandboxBuiltinResult? early})
  parseTreeArgs(List<String> args) {
    var showHidden = false;
    int? maxDepth;
    String? root;
    SandboxBuiltinResult? early;
    for (var i = 0; i < args.length && early == null; i++) {
      final arg = args[i];
      if (arg == '-a') {
        showHidden = true;
      } else if (arg == '--help') {
        early = _ok(utf8.encode('usage: tree [-a] [-L level] [directory]\n'));
      } else if (arg == '-L' || (arg.startsWith('-L') && arg.length > 2)) {
        final (depth, extra, error) = _treeDepthFlag(arg, args, i);
        if (error != null) {
          early = error;
        } else {
          maxDepth = depth;
          i += extra;
        }
      } else if (arg.startsWith('-') && arg != '-') {
        early = _error("tree: Invalid option - '${arg.substring(1)}'\n", 2);
      } else if (root == null) {
        root = arg;
      } else {
        early = _error('tree: too many arguments\n', 2);
      }
    }
    return (showHidden: showHidden, maxDepth: maxDepth, root: root, early: early);
  }

  /// Draws the recursive `tree` listing into [out], counting directories
  /// and files (the executor appends the summary line).
  static Future<({StringBuffer out, int directories, int files})> _renderTree({
    required SandboxDirLister lister,
    required bool showHidden,
    required int? maxDepth,
    required StringBuffer out,
    required String root,
  }) async {
    var directories = 0;
    var files = 0;

    Future<void> walk(String path, String prefix, int depth) async {
      if (maxDepth != null && depth > maxDepth) return;
      final entries = await lister(path);
      if (entries == null) return;
      final visible = [
        for (final entry in entries)
          if (showHidden || !entry.name.startsWith('.')) entry,
      ]..sort((a, b) => a.name.compareTo(b.name));
      for (var k = 0; k < visible.length; k++) {
        final entry = visible[k];
        final last = k == visible.length - 1;
        out
          ..write(prefix)
          ..write(last ? '└── ' : '├── ')
          ..writeln(entry.name);
        if (entry.isDirectory) {
          directories++;
          await walk(
            path.endsWith('/') ? '$path${entry.name}' : '$path/${entry.name}',
            '$prefix${last ? '    ' : '│   '}',
            depth + 1,
          );
        } else {
          files++;
        }
      }
    }

    await walk(root, '', 1);
    return (out: out, directories: directories, files: files);
  }

  /// Runs the `tree` builtin: `tree [path] [-L depth] [-a]` prints a
  /// recursive listing with the classic tree-drawing characters
  /// (`├──`/`└──`/`│`), sorted alphabetically with directories mixed in
  /// (the real tree's default order). Dotfiles are hidden unless `-a` is
  /// given; `-L n` limits the display depth (the root's immediate children
  /// are level 1). The listing ends with a `N directories, M files` summary
  /// line; a file argument prints just itself (`0 directories, 1 file`).
  /// Exit codes: 0 success, 1 when the path does not exist, 2 usage error.
  Future<SandboxBuiltinResult> tree(List<String> args) async {
    final lister = listDirectory;
    if (lister == null) {
      return _error('tree: not supported by this shell\n', 2);
    }
    final t = parseTreeArgs(args);
    if (t.early != null) return t.early!;
    final target = t.root ?? '.';

    final out = StringBuffer()..writeln(target);
    var directories = 0;
    var files = 0;
    if (await lister(target) != null) {
      final rendered = await _renderTree(
        lister: lister,
        showHidden: t.showHidden,
        maxDepth: t.maxDepth,
        out: out,
        root: target,
      );
      directories = rendered.directories;
      files = rendered.files;
    } else {
      // A file root prints itself and counts as one file (like real tree).
      final reader = readBinaryFile;
      if (reader == null || await reader(target) == null) {
        return _error('tree: $target: No such file or directory\n', 1);
      }
      files++;
    }
    out
      ..writeln()
      ..writeln(
        '${directories == 1 ? '1 directory' : '$directories directories'}, '
        '${files == 1 ? '1 file' : '$files files'}',
      );
    return _ok(utf8.encode(out.toString()));
  }

  // ---------------------------------------------------------------------------
  // file
  // ---------------------------------------------------------------------------

  /// Runs the `file` builtin: `file <path...>` classifies each operand by
  /// its magic bytes — the formats the sandbox itself produces or consumes
  /// (wasm, zip, gzip, xz, bzip2, tar, PNG/JPEG/GIF/WebP, PDF, SQLite3,
  /// ELF, Mach-O) — falling back to ASCII/UTF-8 text detection and finally
  /// `data`. Output follows BSD file: `path: description`. Exit codes:
  /// 0 when every operand was classified, 1 when one was missing, 2 usage
  /// error.
  Future<SandboxBuiltinResult> file(List<String> args) async {
    final reader = readBinaryFile;
    if (reader == null) {
      return _error('file: not supported by this shell\n', 2);
    }
    final paths = <String>[];
    for (final arg in args) {
      if (arg.startsWith('-') && arg != '-') {
        return _error("file: invalid option -- '${arg.substring(1)}'\n", 2);
      }
      paths.add(arg);
    }
    if (paths.isEmpty) {
      return _error('usage: file file...\n', 2);
    }
    final out = StringBuffer();
    var failed = false;
    for (final path in paths) {
      final bytes = await reader(path);
      if (bytes == null) {
        out.writeln("$path: cannot open '$path' (No such file or directory)");
        failed = true;
        continue;
      }
      out.writeln('$path: ${_describeBytes(bytes)}');
    }
    return SandboxBuiltinResult(
      stdout: utf8.encode(out.toString()),
      stderr: const [],
      exitCode: failed ? 1 : 0,
    );
  }

  // ---------------------------------------------------------------------------
  // xz / bzip2 (decompress only)
  // ---------------------------------------------------------------------------

  /// Runs the `xz` builtin: decompression only (`xz -d`, or `unxz` with
  /// [decompress] preset). Each `.xz` operand is replaced by its decoded
  /// sibling file (the original is removed unless `-k`); `-c` writes the
  /// decoded bytes to stdout instead and skips the suffix check, mirroring
  /// the codebase's `gzip -d`/`gunzip` behavior. Decoding goes through
  /// `package:archive`'s XZ decoder behind a magic-bytes check (the
  /// package's own error reporting is disabled, so corrupt payloads with a
  /// valid header decode silently — a known limitation). The compress
  /// direction is not supported. Exit codes: 0 success, 1 on
  /// missing/corrupt input, 2 usage error.
  Future<SandboxBuiltinResult> xz(
    List<String> args, {
    bool decompress = false,
  }) {
    return _decompress(
      'xz',
      args,
      decompress: decompress,
      suffix: '.xz',
      decode: (bytes) {
        _requireMagic(bytes, const [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]);
        return XZDecoder().decodeBytes(bytes);
      },
    );
  }

  /// Runs the `bzip2` builtin: decompression only (`bzip2 -d`, or `bunzip2`
  /// with [decompress] preset); behaves exactly like [xz] but for `.bz2`
  /// files via `package:archive`'s bzip2 decoder (same magic-bytes caveat).
  Future<SandboxBuiltinResult> bzip2(
    List<String> args, {
    bool decompress = false,
  }) {
    return _decompress(
      'bzip2',
      args,
      decompress: decompress,
      suffix: '.bz2',
      decode: (bytes) {
        _requireMagic(bytes, 'BZh'.codeUnits);
        return BZip2Decoder().decodeBytes(bytes);
      },
    );
  }

  /// Parses one bundled short-flag cluster (`-dc`, `-dk`, ...) for the
  /// decompress family. Returns which letters it sets plus the usage
  /// error for an unknown letter.
  static (bool, bool, bool, SandboxBuiltinResult?) _decompressShortFlags(
    String arg,
    String name,
  ) {
    var d = false;
    var k = false;
    var c = false;
    for (var j = 1; j < arg.length; j++) {
      switch (arg[j]) {
        case 'd':
          d = true;
        case 'k':
          k = true;
        case 'c':
          c = true;
        default:
          return (d, k, c, _error('$name: unsupported option -${arg[j]}\n', 2));
      }
    }
    return (d, k, c, null);
  }

  /// Pure decompress-family argument parser (`xz`/`bzip2` shape):
  /// `-d`/`--decompress`/`--uncompress`, `-k`/`--keep`, `-c`/`--stdout`/
  /// `--to-stdout`, bundled short flags, and file operands. Any other
  /// option is a usage error. Table-tested; see [xz].
  static ({
    bool unpack,
    bool keep,
    bool toStdout,
    List<String> files,
    SandboxBuiltinResult? error,
  })
  _parseDecompressArgs(String name, List<String> args) {
    var unpack = false;
    var keep = false;
    var toStdout = false;
    final files = <String>[];
    for (final arg in args) {
      if (arg == '-d' || arg == '--decompress' || arg == '--uncompress') {
        unpack = true;
      } else if (arg == '-k' || arg == '--keep') {
        keep = true;
      } else if (arg == '-c' || arg == '--stdout' || arg == '--to-stdout') {
        toStdout = true;
      } else if (arg.startsWith('-') && arg != '-') {
        // Bundled short flags (-dc, -dk, ...).
        final (d, k, c, error) = _decompressShortFlags(arg, name);
        unpack = unpack || d;
        keep = keep || k;
        toStdout = toStdout || c;
        if (error != null) {
          return (
            unpack: unpack,
            keep: keep,
            toStdout: toStdout,
            files: files,
            error: error,
          );
        }
      } else {
        files.add(arg);
      }
    }
    return (
      unpack: unpack,
      keep: keep,
      toStdout: toStdout,
      files: files,
      error: null,
    );
  }
  Future<SandboxBuiltinResult> _decompress(
    String name,
    List<String> args, {
    required bool decompress,
    required String suffix,
    required List<int> Function(List<int> bytes) decode,
  }) async {
    final reader = readBinaryFile;
    if (reader == null) {
      return _error('$name: not supported by this shell\n', 2);
    }
    final parsed = _parseDecompressArgs(name, args);
    if (parsed.error != null) return parsed.error!;
    var unpack = parsed.unpack || decompress;
    final keep = parsed.keep;
    final toStdout = parsed.toStdout;
    final files = parsed.files;
    if (!unpack) {
      return _error(
        '$name: compression is not supported in this sandbox, '
        'use $name -d to decompress\n',
        2,
      );
    }
    if (files.isEmpty) {
      return _error('$name: missing operand\n', 1);
    }
    final stdout = <int>[];
    for (final arg in files) {
      final read = await reader(arg);
      if (read == null) {
        return _error('$name: $arg: No such file or directory\n', 1);
      }
      if (!toStdout && !arg.endsWith(suffix)) {
        return _error('$name: $arg: unknown suffix -- ignored\n', 1);
      }
      final List<int> decoded;
      try {
        decoded = decode(read);
      } on Object {
        return _error('$name: $arg: not in $name format\n', 1);
      }
      if (toStdout) {
        stdout.addAll(decoded);
        continue;
      }
      await writeBinaryFile(
        arg.substring(0, arg.length - suffix.length),
        decoded,
      );
      final remover = removeFile;
      if (!keep && remover != null) await remover(arg);
    }
    return _ok(stdout);
  }

  // ---------------------------------------------------------------------------
  // base64
  // ---------------------------------------------------------------------------


  /// Resolves a `-w`/`--wrap`/`--wrap=`/`-wN` flag. Returns the columns
  /// string (null for the bare `-w`/`--wrap` form) and whether the next
  /// argument was consumed, or null when [arg] is not a wrap flag.
  static (String?, bool)? _base64WrapFlag(String arg) {
    if (arg == '-w' || arg == '--wrap') return (null, true);
    if (arg.startsWith('--wrap=')) return (arg.substring('--wrap='.length), false);
    if (arg.startsWith('-w') && arg.length > 2) {
      return (arg.substring(2), false);
    }
    return null;
  }

  /// Pure `base64` argument parser: `-d`/`--decode`, `-w cols`/`--wrap=cols`
  /// (0 disables wrapping; a negative or non-numeric width is a usage
  /// error), one optional input file, `-` for stdin. The first error wins
  /// and stops parsing. Table-tested; see [base64].
  static Base64Args parseBase64Args(List<String> args) {
    final b = Base64Args();
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      final wrap = _base64WrapFlag(arg);
      if (arg == '-d' || arg == '--decode') {
        b.decode = true;
      } else if (wrap != null) {
        final (columns, consumed) = wrap;
        if (columns == null) {
          if (i + 1 >= args.length) {
            b.error = _error("base64: option requires an argument -- 'w'\n", 2);
            return b;
          }
          b.wrap = _base64WrapValue(args[++i], b);
          if (b.error != null) return b;
        } else {
          b.wrap = _base64WrapValue(columns, b);
          if (b.error != null) return b;
        }
        // The bare flag form consumed its value above via ++i.
        if (!consumed) continue;
      } else if (arg.startsWith('-') && arg != '-') {
        b.error = _error("base64: invalid option -- '${arg.substring(1)}'\n", 2);
        return b;
      } else if (b.inputFile == null) {
        b.inputFile = arg;
      } else {
        b.error = _error("base64: extra operand '$arg'\n", 2);
        return b;
      }
    }
    return b;
  }

  /// Parses a `-w` column count; records the usage error on [b] for a
  /// negative or non-numeric width (matching GNU base64's message).
  static int _base64WrapValue(String columns, Base64Args b) {
    final wrap = int.tryParse(columns) ?? -1;
    if (wrap < 0) {
      b.error = _error("base64: invalid wrap size: '$columns'\n", 2);
    }
    return wrap;
  }

  /// Wraps [encoded] at [wrap] columns (0 = one line) with a trailing
  /// newline, like GNU base64 output.
  static String _base64Wrapped(String encoded, int wrap) {
    if (wrap <= 0) return '$encoded\n';
    final lines = <String>[
      for (var i = 0; i < encoded.length; i += wrap)
        encoded.substring(
          i,
          i + wrap > encoded.length ? encoded.length : i + wrap,
        ),
    ];
    return '${lines.join('\n')}\n';
  }

  /// Runs the `base64` builtin: `base64 [-d|--decode] [-w cols] [file]`.
  /// Encoding wraps at 76 columns by default (GNU behavior; `-w 0` disables
  /// wrapping) and ends with a newline; `-d` decodes, tolerating whitespace
  /// in the input. Input comes from [file], or from [stdin] when no file
  /// (or `-`) is given. Exit codes: 0 success, 1 on invalid input or a
  /// missing file, 2 usage error.
  Future<SandboxBuiltinResult> base64(
    List<String> args, {
    String? stdin,
  }) async {
    final b = parseBase64Args(args);
    if (b.error != null) return b.error!;

    final List<int> input;
    if (b.inputFile != null && b.inputFile != '-') {
      final reader = readBinaryFile;
      if (reader == null) {
        return _error('base64: not supported by this shell\n', 2);
      }
      final read = await reader(b.inputFile!);
      if (read == null) {
        return _error('base64: ${b.inputFile}: No such file or directory\n', 1);
      }
      input = read;
    } else {
      input = utf8.encode(stdin ?? '');
    }

    if (b.decode) {
      final text = utf8
          .decode(input, allowMalformed: true)
          .replaceAll(RegExp(r'\s'), '');
      final List<int> decoded;
      try {
        decoded = base64Decode(text);
      } on FormatException {
        return _error('base64: invalid input\n', 1);
      }
      return _ok(decoded);
    }

    final encoded = base64Encode(input);
    if (encoded.isEmpty) return _ok(const []);
    return _ok(utf8.encode(_base64Wrapped(encoded, b.wrap)));
  }

  // ---------------------------------------------------------------------------
  // md5sum / sha*sum
  // ---------------------------------------------------------------------------

  /// Maps a checksum builtin name to its `package:crypto` hasher.
  static Hash _hashFor(String name) => switch (name) {
    'md5sum' => md5,
    'sha1sum' => sha1,
    'sha224sum' => sha224,
    'sha256sum' => sha256,
    'sha384sum' => sha384,
    'sha512sum' => sha512,
    _ => throw ArgumentError.value(name, 'name', 'unsupported checksum'),
  };

  /// Pure checksum-builtin argument parser: `-b`/`-t`/`--binary`/`--text`
  /// are accepted no-ops (no CRLF translation in the sandbox), any other
  /// option is a usage error, and the operands default to `-` (stdin).
  /// Table-tested; see [hashsum].
  static (List<String>, SandboxBuiltinResult?) _parseHashsumArgs(
    String name,
    List<String> args,
  ) {
    final paths = <String>[];
    for (final arg in args) {
      if (arg == '-b' || arg == '-t' || arg == '--binary' || arg == '--text') {
        // Binary/text mode is a no-op in the sandbox (no CRLF translation).
      } else if (arg.startsWith('-') && arg != '-') {
        return (
          const [],
          _error("$name: invalid option -- '${arg.substring(1)}'\n", 2),
        );
      } else {
        paths.add(arg);
      }
    }
    if (paths.isEmpty) paths.add('-');
    return (paths, null);
  }

  /// Runs a checksum builtin selected by [name] (`md5sum`, `sha1sum`,
  /// `sha224sum`, `sha256sum`, `sha384sum`, `sha512sum`), printing
  /// `<hex digest>  <path>` per operand like the GNU tools. With no operand
  /// (or `-`) the input is read from [stdin] and reported as `-`. Digests
  /// come from `package:crypto`. Exit codes: 0 when every operand hashed,
  /// 1 when one was missing, 2 usage error.
  Future<SandboxBuiltinResult> hashsum(
    String name,
    List<String> args, {
    String? stdin,
  }) async {
    final hash = _hashFor(name);
    final (paths, error) = _parseHashsumArgs(name, args);
    if (error != null) return error;

    final reader = readBinaryFile;
    if (reader == null) {
      return _error('$name: not supported by this shell\n', 2);
    }
    final out = StringBuffer();
    final err = StringBuffer();
    var failed = false;
    for (final path in paths) {
      final bytes = path == '-' ? utf8.encode(stdin ?? '') : await reader(path);
      if (bytes == null) {
        err.writeln('$name: $path: No such file or directory');
        failed = true;
        continue;
      }
      out.writeln('${hash.convert(bytes)}  $path');
    }
    return SandboxBuiltinResult(
      stdout: utf8.encode(out.toString()),
      stderr: utf8.encode(err.toString()),
      exitCode: failed ? 1 : 0,
    );
  }
  /// Pure `unzip` argument parser: `-d dir` (target directory), `-q`/`-o`
  /// accepted as no-ops (quiet/overwrite are the defaults), archive
  /// operands. Any other option is an error (exit code 1, matching the
  /// sandbox unzip's convention). Table-tested; see [unzip].
  static ({
    String? destDir,
    List<String> archives,
    SandboxBuiltinResult? error,
  })
  parseUnzipArgs(List<String> args) {
    String? destDir;
    final archives = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-d' && i + 1 < args.length) {
        destDir = args[++i];
      } else if (arg == '-q' || arg == '-o') {
        // Quiet/overwrite are the defaults in this subset.
      } else if (arg.startsWith('-') && arg != '-') {
        return (
          destDir: destDir,
          archives: archives,
          error: _error('unzip: unsupported option $arg\n', 1),
        );
      } else {
        archives.add(arg);
      }
    }
    return (destDir: destDir, archives: archives, error: null);
  }

  /// Extracts every regular file of [archive] under [root], recreating
  /// directories through [makeDirectory] and writing entries through
  /// [writeBinaryFile]. Leading slashes are stripped from entry names.
  static Future<void> _extractZip(
    Archive archive,
    String root, {
    required Future<void> Function(String path, List<int> bytes)
    writeBinaryFile,
    required Future<void> Function(String path)? makeDirectory,
  }) async {
    for (final file in archive.files) {
      final name = file.name.startsWith('/')
          ? file.name.substring(1)
          : file.name;
      if (!file.isFile || name.endsWith('/')) {
        await makeDirectory?.call('$root/$name');
        continue;
      }
      await writeBinaryFile('$root/$name', file.content as List<int>);
    }
  }

  /// Runs the `unzip` builtin: extracts zip archives (via package:archive)
  /// into the current directory, or into the directory given with `-d`.
  /// `-q`/`-o` are accepted as no-ops (quiet/overwrite are the defaults).
  Future<SandboxBuiltinResult> unzip(List<String> args) async {
    final reader = readBinaryFile;
    if (reader == null) {
      return _error('unzip: not supported by this shell\n', 1);
    }
    final u = parseUnzipArgs(args);
    if (u.error != null) return u.error!;
    if (u.archives.isEmpty) {
      return _error('unzip: missing archive operand\n', 1);
    }
    for (final arg in u.archives) {
      final bytes = await reader(arg);
      if (bytes == null) {
        return _error(
          'unzip: cannot find or open $arg, $arg.zip or $arg.ZIP\n',
          1,
        );
      }
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(bytes);
      } on Object {
        return _error('unzip: $arg: not in zip format\n', 1);
      }
      await _extractZip(
        archive,
        u.destDir ?? '.',
        writeBinaryFile: writeBinaryFile,
        makeDirectory: makeDirectory,
      );
    }
    return _ok(const []);
  }
}
