// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:diffutil_dart/diffutil.dart' as diffutil;
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart' as yaml;

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

  /// Runs the `curl` builtin: HTTP via [_httpClient] with the common flag
  /// subset (`-X`, `-H`, `-d`, `-o`, `-s`, `-L`, `--version`, `--help`).
  Future<SandboxBuiltinResult> curl(
    List<String> args, {
    Duration? timeout,
  }) async {
    if (args.contains('--version') || args.contains('-V')) {
      return _ok(
        utf8.encode(
          'curl 8.5.0 (fah-sandbox) Dart (fah-sandbox)\n'
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
          ' -d, --data <data>        HTTP POST data\n'
          ' -o, --output <file>      Write to file instead of stdout\n'
          ' -s, --silent             Silent mode\n'
          ' -L, --location           Follow redirects\n'
          ' -V, --version            Show version\n',
        ),
      );
    }
    final parsed = _parseCurlArgs(args);
    if (parsed.url == null) {
      return _error('curl: no URL specified\n', 2);
    }

    Uri uri;
    try {
      uri = Uri.parse(parsed.url!);
    } on FormatException {
      return _error('curl: invalid URL\n', 3);
    }

    final request = http.Request(parsed.method, uri);
    request.headers.addAll(parsed.headers);
    if (parsed.body != null) request.body = parsed.body!;
    request.followRedirects = parsed.followRedirects;

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

  /// Runs the `wget` builtin: a thin alias over [curl] translating
  /// `wget [-q] [-O file] URL` into the equivalent curl flags.
  Future<SandboxBuiltinResult> wget(
    List<String> args, {
    Duration? timeout,
  }) async {
    if (args.contains('--version') || args.contains('-V')) {
      return _ok(utf8.encode('GNU Wget 1.21.4 (fah-sandbox builtin)\n'));
    }
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
    return curl(curlArgs, timeout: timeout);
  }

  ({
    String? url,
    String method,
    Map<String, String> headers,
    String? body,
    String? outputFile,
    bool silent,
    bool followRedirects,
  })
  _parseCurlArgs(List<String> args) {
    var method = 'GET';
    final headers = <String, String>{};
    String? body;
    String? outputFile;
    var silent = false;
    var followRedirects = false;
    String? url;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-X' || arg == '--request') {
        if (i + 1 < args.length) method = args[++i];
      } else if (arg == '-H' || arg == '--header') {
        if (i + 1 < args.length) {
          final header = args[++i];
          final idx = header.indexOf(':');
          if (idx > 0) {
            headers[header.substring(0, idx).trim()] = header
                .substring(idx + 1)
                .trim();
          }
        }
      } else if (arg == '-d' || arg == '--data' || arg == '--data-raw') {
        if (i + 1 < args.length) body = args[++i];
      } else if (arg == '-o' || arg == '--output') {
        if (i + 1 < args.length) outputFile = args[++i];
      } else if (arg == '-s' || arg == '--silent') {
        silent = true;
      } else if (arg == '-L' || arg == '--location') {
        followRedirects = true;
      } else if (arg == '--url') {
        if (i + 1 < args.length) url = args[++i];
      } else if (!arg.startsWith('-')) {
        url = arg;
      }
    }

    return (
      url: url,
      method: method,
      headers: headers,
      body: body,
      outputFile: outputFile,
      silent: silent,
      followRedirects: followRedirects,
    );
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
    if (args.isEmpty) {
      return _error('$name: missing filter\n', 2);
    }
    final filter = args.first;

    final String content;
    if (args.length > 1) {
      final inputFile = args[1];
      final read = await readTextFile(inputFile);
      if (read == null) {
        return _error('$name: $inputFile: No such file or directory\n', 2);
      }
      content = read;
    } else if (stdin != null) {
      content = stdin;
    } else {
      return _error('$name: missing input\n', 2);
    }

    final parsed = parse(content);
    if (parsed.error != null) {
      return _error(parsed.error!, 5);
    }

    final results = _applyJqFilter(parsed.value, filter);
    const encoder = JsonEncoder.withIndent('  ');
    final output = results.map(encoder.convert).join('\n');
    return _ok(utf8.encode(output.isNotEmpty ? '$output\n' : ''));
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
    var brief = false;
    var newFile = false;
    var context = 3;
    final operands = <String>[];
    var noMoreFlags = false;
    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      if (!noMoreFlags && arg == '--') {
        noMoreFlags = true;
      } else if (!noMoreFlags && arg == '--brief') {
        brief = true;
      } else if (!noMoreFlags && arg == '--new-file') {
        newFile = true;
      } else if (!noMoreFlags && arg == '--unified') {
        // Unified output is the default.
      } else if (!noMoreFlags && arg.startsWith('-') && arg != '-') {
        for (var j = 1; j < arg.length; j++) {
          final flag = arg[j];
          switch (flag) {
            case 'u':
              break; // Unified output is the default.
            case 'q':
              brief = true;
            case 'N':
              newFile = true;
            case 'U':
              final inline = arg.substring(j + 1);
              final value = inline.isNotEmpty
                  ? inline
                  : (i + 1 < args.length ? args[++i] : '');
              final parsed = int.tryParse(value);
              if (parsed == null || parsed < 0) {
                return _error("diff: invalid context length '$value'\n", 2);
              }
              context = parsed;
              j = arg.length; // The rest of the arg is the number.
            default:
              return _error("diff: invalid option -- '$flag'\n", 2);
          }
        }
      } else {
        operands.add(arg);
      }
      i++;
    }
    if (operands.length != 2) {
      return _error('diff: expected two file operands\n', 2);
    }

    Future<String?> readOperand(String name) async {
      if (name == '-') return stdin ?? '';
      final read = await readTextFile(name);
      return read ?? (newFile ? '' : null);
    }

    final oldContent = await readOperand(operands[0]);
    if (oldContent == null) {
      return _error('diff: ${operands[0]}: No such file or directory\n', 2);
    }
    final newContent = await readOperand(operands[1]);
    if (newContent == null) {
      return _error('diff: ${operands[1]}: No such file or directory\n', 2);
    }

    final oldDoc = _LineDoc(oldContent);
    final newDoc = _LineDoc(newContent);
    final ops = _diffOps(oldDoc.tokens, newDoc.tokens);
    final differ = ops.any((op) => op.kind != _DiffOpKind.context);
    if (!differ) return _ok(const []);
    if (brief) {
      return SandboxBuiltinResult(
        stdout: utf8.encode('Files ${operands[0]} and ${operands[1]} differ\n'),
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
          oldLabel: operands[0],
          newLabel: operands[1],
          context: context,
        ),
      ),
      stderr: const [],
      exitCode: 1,
    );
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
        final String value;
        if (arg.startsWith('--strip=')) {
          value = arg.substring('--strip='.length);
        } else if (arg == '--strip' || arg == '-p') {
          if (i + 1 >= args.length) {
            return _error('patch: option requires an argument -- p\n', 2);
          }
          value = args[++i];
        } else if (arg.startsWith('-p') && !arg.startsWith('--')) {
          value = arg.substring(2);
        } else {
          return _error("patch: unrecognized option '$arg'\n", 2);
        }
        final parsed = int.tryParse(value);
        if (parsed == null || parsed < 0) {
          return _error("patch: invalid strip count '$value'\n", 2);
        }
        strip = parsed;
      } else if (!noMoreFlags &&
          (arg.startsWith('-i') || arg.startsWith('--input'))) {
        if (arg.startsWith('--input=')) {
          patchFile = arg.substring('--input='.length);
        } else if (arg == '--input' || arg == '-i') {
          if (i + 1 >= args.length) {
            return _error('patch: option requires an argument -- i\n', 2);
          }
          patchFile = args[++i];
        } else if (arg.startsWith('-i') && !arg.startsWith('--')) {
          patchFile = arg.substring(2);
        } else {
          return _error("patch: unrecognized option '$arg'\n", 2);
        }
      } else if (!noMoreFlags && arg.startsWith('-') && arg != '-') {
        return _error("patch: unrecognized option '$arg'\n", 2);
      } else {
        positional.add(arg);
      }
      i++;
    }
    if (positional.length > 2) {
      return _error('patch: too many file arguments\n', 2);
    }
    final target = positional.isNotEmpty ? positional[0] : null;
    if (positional.length > 1) patchFile ??= positional[1];

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

  // ---------------------------------------------------------------------------
  // nslookup / dig / whois
  // ---------------------------------------------------------------------------

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
    final out = StringBuffer();

    final ptrName = ipv4PtrName(host);
    if (ptrName != null) {
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
  Future<SandboxBuiltinResult> dig(
    List<String> args, {
    Duration? timeout,
  }) async {
    var reverse = false;
    String? name;
    var type = 'A';
    for (final arg in args) {
      if (arg == '-x') {
        reverse = true;
      } else if (arg.startsWith('-')) {
        return _error("dig: unknown option '$arg'\n", 2);
      } else if (name == null) {
        name = arg;
      } else {
        final upper = arg.toUpperCase();
        if (!_digTypes.contains(upper)) {
          return _error("dig: unknown query type '$arg'\n", 2);
        }
        if (type != 'A') {
          return _error('usage: dig [-x] <host> [TYPE]\n', 2);
        }
        type = upper;
      }
    }
    if (name == null) {
      return _error('usage: dig [-x] <host> [TYPE]\n', 2);
    }
    if (reverse) {
      final ptrName = ipv4PtrName(name);
      if (ptrName == null) {
        return _error('dig: -x expects an IPv4 address\n', 2);
      }
      name = ptrName;
      type = 'PTR';
    }

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

  /// Renders an RDAP JSON document as compact whois-style `Key: value`
  /// lines; falls back to pretty-printed JSON when the document has none of
  /// the recognized fields.
  static String _rdapSummary(Object? doc) {
    if (doc is Map<String, dynamic>) {
      final out = StringBuffer();
      final isDomain = doc['objectClassName'] == 'domain';
      void field(String label, Object? value) {
        if (value is String && value.isNotEmpty) {
          out.writeln('$label: $value');
        }
      }

      if (isDomain) {
        field('Domain Name', doc['ldhName']);
        field('Registry Domain ID', doc['handle']);
      } else {
        field('NetName', doc['name']);
        field('NetHandle', doc['handle']);
        final start = doc['startAddress'];
        final end = doc['endAddress'];
        if (start is String && end is String) {
          out.writeln('NetRange: $start - $end');
        }
        field('Country', doc['country']);
      }
      final status = doc['status'];
      if (status is List) {
        for (final value in status) {
          field(isDomain ? 'Domain Status' : 'Status', value);
        }
      }
      final entities = doc['entities'];
      if (entities is List) {
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
      final events = doc['events'];
      if (events is List) {
        for (final event in events) {
          if (event is! Map<String, dynamic>) continue;
          final action = event['eventAction'];
          final date = event['eventDate'];
          if (action is! String || date is! String) continue;
          out.writeln('${_rdapEventName(action)}: $date');
        }
      }
      final nameservers = doc['nameservers'];
      if (nameservers is List) {
        for (final ns in nameservers) {
          if (ns is Map<String, dynamic>) field('Name Server', ns['ldhName']);
        }
      }
      if (out.isNotEmpty) return out.toString();
    }
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

  List<dynamic> _applyJqFilter(dynamic input, String filter) {
    if (filter == '.') return [input];
    if (filter == 'length') {
      if (input is List || input is String || input is Map) {
        return [(input as dynamic).length as Object];
      }
      return const [];
    }
    if (filter == 'keys') {
      if (input is Map) return [input.keys.toList()];
      return const [];
    }

    final parts = filter.split('.').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return [input];

    dynamic current = input;
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final isLast = i == parts.length - 1;
      if (part == '[]') {
        if (current is List) {
          final rest = parts.sublist(i + 1).join('.');
          return current
              .expand((e) => _applyJqFilter(e, rest.isEmpty ? '.' : '.$rest'))
              .toList();
        }
        return const [];
      }
      if (isLast && part == 'length') {
        if (current is List || current is String || current is Map) {
          return [(current as dynamic).length as Object];
        }
        return const [];
      }
      if (isLast && part == 'keys') {
        if (current is Map) return [current.keys.toList()];
        return const [];
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
    var showHidden = false;
    int? maxDepth;
    String? root;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-a') {
        showHidden = true;
      } else if (arg == '--help') {
        return _ok(utf8.encode('usage: tree [-a] [-L level] [directory]\n'));
      } else if (arg == '-L' || (arg.startsWith('-L') && arg.length > 2)) {
        final value = arg == '-L'
            ? (i + 1 < args.length ? args[++i] : null)
            : arg.substring(2);
        if (value == null) {
          return _error('tree: Missing argument to -L option.\n', 2);
        }
        maxDepth = int.tryParse(value);
        if (maxDepth == null || maxDepth < 1) {
          return _error('tree: Invalid level, must be greater than 0.\n', 2);
        }
      } else if (arg.startsWith('-') && arg != '-') {
        return _error("tree: Invalid option - '${arg.substring(1)}'\n", 2);
      } else if (root == null) {
        root = arg;
      } else {
        return _error('tree: too many arguments\n', 2);
      }
    }
    final target = root ?? '.';

    final out = StringBuffer()..writeln(target);
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

    if (await lister(target) != null) {
      await walk(target, '', 1);
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
    var unpack = decompress;
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
      } else if (arg.startsWith('--')) {
        return _error('$name: unsupported option $arg\n', 2);
      } else if (arg.startsWith('-') && arg != '-') {
        // Bundled short flags (-dc, -dk, ...).
        for (var j = 1; j < arg.length; j++) {
          switch (arg[j]) {
            case 'd':
              unpack = true;
            case 'k':
              keep = true;
            case 'c':
              toStdout = true;
            default:
              return _error('$name: unsupported option -${arg[j]}\n', 2);
          }
        }
      } else {
        files.add(arg);
      }
    }
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
    var decode = false;
    var wrap = 76;
    String? inputFile;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String? columns;
      if (arg == '-d' || arg == '--decode') {
        decode = true;
      } else if (arg == '-w' || arg == '--wrap') {
        columns = i + 1 < args.length ? args[++i] : null;
        if (columns == null) {
          return _error("base64: option requires an argument -- 'w'\n", 2);
        }
      } else if (arg.startsWith('--wrap=')) {
        columns = arg.substring('--wrap='.length);
      } else if (arg.startsWith('-w') && arg.length > 2) {
        columns = arg.substring(2);
      } else if (arg.startsWith('-') && arg != '-') {
        return _error("base64: invalid option -- '${arg.substring(1)}'\n", 2);
      } else if (inputFile == null) {
        inputFile = arg;
      } else {
        return _error("base64: extra operand '$arg'\n", 2);
      }
      if (columns != null) {
        wrap = int.tryParse(columns) ?? -1;
        if (wrap < 0) {
          return _error("base64: invalid wrap size: '$columns'\n", 2);
        }
      }
    }

    final List<int> input;
    if (inputFile != null && inputFile != '-') {
      final reader = readBinaryFile;
      if (reader == null) {
        return _error('base64: not supported by this shell\n', 2);
      }
      final read = await reader(inputFile);
      if (read == null) {
        return _error('base64: $inputFile: No such file or directory\n', 1);
      }
      input = read;
    } else {
      input = utf8.encode(stdin ?? '');
    }

    if (decode) {
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
    final lines = <String>[
      if (wrap > 0)
        for (var i = 0; i < encoded.length; i += wrap)
          encoded.substring(
            i,
            i + wrap > encoded.length ? encoded.length : i + wrap,
          )
      else
        encoded,
    ];
    return _ok(utf8.encode('${lines.join('\n')}\n'));
  }

  // ---------------------------------------------------------------------------
  // md5sum / sha*sum
  // ---------------------------------------------------------------------------

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
    final hash = switch (name) {
      'md5sum' => md5,
      'sha1sum' => sha1,
      'sha224sum' => sha224,
      'sha256sum' => sha256,
      'sha384sum' => sha384,
      'sha512sum' => sha512,
      _ => throw ArgumentError.value(name, 'name', 'unsupported checksum'),
    };
    final paths = <String>[];
    for (final arg in args) {
      if (arg == '-b' || arg == '-t' || arg == '--binary' || arg == '--text') {
        // Binary/text mode is a no-op in the sandbox (no CRLF translation).
      } else if (arg.startsWith('-') && arg != '-') {
        return _error("$name: invalid option -- '${arg.substring(1)}'\n", 2);
      } else {
        paths.add(arg);
      }
    }
    if (paths.isEmpty) paths.add('-');

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
}

// ---------------------------------------------------------------------------
// file(1) magic helpers
// ---------------------------------------------------------------------------

/// Whether [bytes] starts with [magic].
bool _hasPrefix(List<int> bytes, List<int> magic) =>
    _hasMagicAt(bytes, 0, magic);

/// Whether [bytes] carries [magic] at [offset].
bool _hasMagicAt(List<int> bytes, int offset, List<int> magic) {
  if (bytes.length < offset + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic[i]) return false;
  }
  return true;
}

/// Throws a [FormatException] unless [bytes] starts with [magic]. The
/// `package:archive` XZ/bzip2 decoders fail silently on malformed input
/// (their error reporting is commented out upstream), so decompression
/// validates the signature itself before decoding.
void _requireMagic(List<int> bytes, List<int> magic) {
  if (!_hasPrefix(bytes, magic)) {
    throw const FormatException('unexpected file signature');
  }
}

/// Classifies [bytes] BSD-file style by magic-number matching; the subset
/// covers the formats the sandbox can produce or consume. Falls back to
/// text detection and finally `data`.
String _describeBytes(List<int> bytes) {
  if (bytes.isEmpty) return 'empty';
  if (_hasPrefix(bytes, const [0x00, 0x61, 0x73, 0x6d])) {
    // The wasm version is a little-endian uint32 at offset 4 (1 = MVP).
    if (bytes.length >= 8) {
      final version =
          bytes[4] +
          bytes[5] * 0x100 +
          bytes[6] * 0x10000 +
          bytes[7] * 0x1000000;
      return 'WebAssembly (wasm) binary module version 0x$version (MVP)';
    }
    return 'WebAssembly (wasm) binary module';
  }
  if (_hasPrefix(bytes, const [0x50, 0x4b, 0x03, 0x04]) ||
      _hasPrefix(bytes, const [0x50, 0x4b, 0x05, 0x06]) ||
      _hasPrefix(bytes, const [0x50, 0x4b, 0x07, 0x08])) {
    return 'Zip archive data';
  }
  if (_hasPrefix(bytes, const [0x1f, 0x8b])) return 'gzip compressed data';
  if (_hasPrefix(bytes, const [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])) {
    return 'XZ compressed data';
  }
  if (_hasPrefix(bytes, const [0x42, 0x5a, 0x68])) {
    final digit = bytes.length > 3 ? bytes[3] : 0;
    final blockSize = digit >= 0x31 && digit <= 0x39
        ? ', block size = ${digit - 0x30}00k'
        : '';
    return 'bzip2 compressed data$blockSize';
  }
  if (_hasPrefix(bytes, const [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ])) {
    return 'PNG image data';
  }
  if (_hasPrefix(bytes, const [0xff, 0xd8, 0xff])) return 'JPEG image data';
  if (_hasPrefix(bytes, 'GIF87a'.codeUnits)) {
    return 'GIF image data, version 87a';
  }
  if (_hasPrefix(bytes, 'GIF89a'.codeUnits)) {
    return 'GIF image data, version 89a';
  }
  if (_hasPrefix(bytes, 'RIFF'.codeUnits) &&
      _hasMagicAt(bytes, 8, 'WEBP'.codeUnits)) {
    return 'RIFF (little-endian) data, Web/P image';
  }
  if (_hasPrefix(bytes, '%PDF-'.codeUnits)) return 'PDF document';
  if (_hasPrefix(bytes, 'SQLite format 3\x00'.codeUnits)) {
    return 'SQLite 3.x database';
  }
  if (_hasMagicAt(bytes, 257, 'ustar'.codeUnits)) return 'POSIX tar archive';
  if (_hasPrefix(bytes, const [0x7f, 0x45, 0x4c, 0x46])) {
    if (bytes.length < 6) return 'ELF executable';
    final bits = bytes[4] == 1 ? '32-bit' : '64-bit';
    final endian = bytes[5] == 2 ? 'MSB' : 'LSB';
    return 'ELF $bits $endian executable';
  }
  if (_hasPrefix(bytes, const [0xfe, 0xed, 0xfa, 0xce]) ||
      _hasPrefix(bytes, const [0xce, 0xfa, 0xed, 0xfe])) {
    return 'Mach-O 32-bit executable';
  }
  if (_hasPrefix(bytes, const [0xfe, 0xed, 0xfa, 0xcf]) ||
      _hasPrefix(bytes, const [0xcf, 0xfa, 0xed, 0xfe])) {
    return 'Mach-O 64-bit executable';
  }
  if (_hasPrefix(bytes, const [0xca, 0xfe, 0xba, 0xbe])) {
    return 'Mach-O universal binary';
  }
  if (_isUtf8Text(bytes)) {
    return bytes.every((b) => b < 0x80) ? 'ASCII text' : 'UTF-8 Unicode text';
  }
  return 'data';
}

/// Whether [bytes] decode as UTF-8 without control characters other than
/// the common whitespace ones (tab, LF, CR, FF).
bool _isUtf8Text(List<int> bytes) {
  try {
    utf8.decode(bytes);
  } on FormatException {
    return false;
  }
  for (final b in bytes) {
    if (b < 0x20 && b != 0x09 && b != 0x0a && b != 0x0d && b != 0x0c) {
      return false;
    }
    if (b == 0x7f) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// diff/patch helpers
// ---------------------------------------------------------------------------

/// A text file viewed as lines: the line contents (without terminators),
/// whether the file ends with a newline, and the comparison tokens that make
/// a missing trailing newline visible to the diff.
final class _LineDoc {
  _LineDoc(String content)
    : trailingNewline = content.isEmpty || content.endsWith('\n'),
      lines = _splitLines(content) {
    tokens = trailingNewline || lines.isEmpty
        ? lines
        : [...lines.sublist(0, lines.length - 1), '${lines.last}\x00'];
  }

  static List<String> _splitLines(String content) {
    if (content.isEmpty) return const [];
    final lines = content.split('\n');
    if (content.endsWith('\n')) lines.removeLast();
    return lines;
  }

  /// Line contents without line terminators.
  final List<String> lines;

  /// Whether the file ends with a newline.
  final bool trailingNewline;

  /// Line tokens for comparison; the `\x00` sentinel suffix marks a last
  /// line without a trailing newline so it differs from its terminated twin.
  late final List<String> tokens;
}

/// One line operation in a computed diff: [context] lines are present in
/// both files, [delete] lines only in the old file, [insert] lines only in
/// the new file.
enum _DiffOpKind { context, delete, insert }

/// A single line operation with its position in both files.
final class _DiffOp {
  const _DiffOp({
    required this.kind,
    required this.oldIndex,
    required this.newIndex,
    required this.oldBefore,
    required this.newBefore,
  });

  final _DiffOpKind kind;

  /// Index into the old/new token list ([oldIndex] is -1 for inserts,
  /// [newIndex] is -1 for deletes).
  final int oldIndex;
  final int newIndex;

  /// Number of old/new lines consumed before this op; used in hunk headers.
  final int oldBefore;
  final int newBefore;
}

/// Computes the line op sequence transforming [oldTokens] into [newTokens]
/// with the Myers algorithm from `package:diffutil_dart`. The package emits
/// RecyclerView-style updates; replaying them over a list of old line
/// indices yields the old→new line mapping.
List<_DiffOp> _diffOps(List<String> oldTokens, List<String> newTokens) {
  final result = diffutil.calculateListDiff<String>(
    oldTokens,
    newTokens,
    detectMoves: false,
  );
  // Replay the updates. Tokens hold the old line index, or -1 for inserted
  // lines. With string line equality and no move detection only Insert and
  // Remove updates are ever produced.
  final replay = [for (var i = 0; i < oldTokens.length; i++) i];
  for (final update in result.getUpdates(batch: false)) {
    switch (update) {
      case diffutil.Insert(:final position, :final count):
        replay.insertAll(position, List.filled(count, -1));
      case diffutil.Remove(:final position, :final count):
        for (var k = 0; k < count; k++) {
          replay.removeAt(position);
        }
      case diffutil.Change() || diffutil.Move():
        throw StateError('unexpected diff update: $update');
    }
  }
  final oldToNew = List.filled(oldTokens.length, -1);
  final newToOld = List.filled(newTokens.length, -1);
  for (var j = 0; j < replay.length; j++) {
    final oldIndex = replay[j];
    if (oldIndex >= 0) {
      oldToNew[oldIndex] = j;
      newToOld[j] = oldIndex;
    }
  }
  final ops = <_DiffOp>[];
  var i = 0;
  var j = 0;
  while (i < oldTokens.length || j < newTokens.length) {
    if (i < oldTokens.length && oldToNew[i] == -1) {
      ops.add(
        _DiffOp(
          kind: _DiffOpKind.delete,
          oldIndex: i,
          newIndex: -1,
          oldBefore: i,
          newBefore: j,
        ),
      );
      i++;
    } else if (j < newTokens.length && newToOld[j] == -1) {
      ops.add(
        _DiffOp(
          kind: _DiffOpKind.insert,
          oldIndex: -1,
          newIndex: j,
          oldBefore: i,
          newBefore: j,
        ),
      );
      j++;
    } else {
      ops.add(
        _DiffOp(
          kind: _DiffOpKind.context,
          oldIndex: i,
          newIndex: j,
          oldBefore: i,
          newBefore: j,
        ),
      );
      i++;
      j++;
    }
  }
  return ops;
}

/// Renders [ops] as a unified diff with `---`/`+++` file headers and
/// `@@ -a,b +c,d @@` hunks with [context] lines of context, mirroring
/// `diff -u` (including `\ No newline at end of file` markers).
String _formatUnified(
  List<_DiffOp> ops,
  List<String> oldTokens,
  List<String> newTokens, {
  required String oldLabel,
  required String newLabel,
  required int context,
}) {
  final out = StringBuffer()
    ..writeln('--- $oldLabel')
    ..writeln('+++ $newLabel');
  var i = 0;
  while (i < ops.length) {
    // Hunks only exist around changes; skip leading context.
    var change = i;
    while (change < ops.length && ops[change].kind == _DiffOpKind.context) {
      change++;
    }
    if (change == ops.length) break;
    final hunkStart = change - context > 0 ? change - context : 0;
    // Extend the hunk while changes are separated by at most 2*context
    // context lines; a larger gap starts a new hunk.
    var lastChange = change;
    var j = change + 1;
    while (j < ops.length) {
      if (ops[j].kind != _DiffOpKind.context) {
        lastChange = j;
        j++;
      } else if (j - lastChange > 2 * context) {
        break;
      } else {
        j++;
      }
    }
    var hunkEnd = lastChange + context + 1;
    if (hunkEnd > ops.length) hunkEnd = ops.length;

    var oldCount = 0;
    var newCount = 0;
    for (var k = hunkStart; k < hunkEnd; k++) {
      if (ops[k].kind != _DiffOpKind.insert) oldCount++;
      if (ops[k].kind != _DiffOpKind.delete) newCount++;
    }
    final first = ops[hunkStart];
    final oldStart = oldCount == 0 ? first.oldBefore : first.oldBefore + 1;
    final newStart = newCount == 0 ? first.newBefore : first.newBefore + 1;
    out.writeln(
      '@@ -${_hunkRange(oldStart, oldCount)} '
      '+${_hunkRange(newStart, newCount)} @@',
    );
    for (var k = hunkStart; k < hunkEnd; k++) {
      final op = ops[k];
      final token = op.kind == _DiffOpKind.insert
          ? newTokens[op.newIndex]
          : oldTokens[op.oldIndex];
      final noNewline = token.endsWith('\x00');
      final text = noNewline ? token.substring(0, token.length - 1) : token;
      final prefix = switch (op.kind) {
        _DiffOpKind.context => ' ',
        _DiffOpKind.delete => '-',
        _DiffOpKind.insert => '+',
      };
      out.writeln('$prefix$text');
      if (noNewline) out.writeln('\\ No newline at end of file');
    }
    i = hunkEnd;
  }
  return out.toString();
}

/// Formats one hunk range; a single-line range omits the count like GNU diff.
String _hunkRange(int start, int count) {
  return count == 1 ? '$start' : '$start,$count';
}

/// One file section of a parsed unified diff.
final class _PatchFile {
  const _PatchFile({
    required this.oldName,
    required this.newName,
    required this.hunks,
  });

  final String oldName;
  final String newName;
  final List<_PatchHunk> hunks;

  /// The file to patch: the new name, unless the patch deletes the file.
  String get targetName => newName == '/dev/null' ? oldName : newName;

  /// Whether the patch creates the file (old name is `/dev/null`).
  bool get createsFile => oldName == '/dev/null';

  /// Whether the patch deletes the file (new name is `/dev/null`).
  bool get deletesFile => newName == '/dev/null';
}

/// One parsed `@@` hunk: header coordinates plus the raw body lines
/// (including `\ No newline at end of file` markers).
final class _PatchHunk {
  const _PatchHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.body,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> body;
}

final _hunkHeaderPattern = RegExp(
  r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
);

/// Parses unified-diff [text] into per-file sections. Preamble lines (such
/// as `diff --git` or `index` lines from git) are skipped; hunk bodies are
/// read by line count, so surrounding garbage cannot corrupt a hunk.
/// Returns null when the input is structurally malformed.
List<_PatchFile>? _parsePatch(String text) {
  final lines = text.split('\n');
  final files = <_PatchFile>[];
  var i = 0;
  while (i < lines.length) {
    if (!lines[i].startsWith('--- ')) {
      i++;
      continue;
    }
    final oldName = _patchFileName(lines[i].substring(4));
    i++;
    if (i >= lines.length || !lines[i].startsWith('+++ ')) return null;
    final newName = _patchFileName(lines[i].substring(4));
    i++;
    final hunks = <_PatchHunk>[];
    while (i < lines.length && lines[i].startsWith('@@ ')) {
      final match = _hunkHeaderPattern.firstMatch(lines[i]);
      if (match == null) return null;
      final oldStart = int.parse(match[1]!);
      final oldCount = match[2] != null ? int.parse(match[2]!) : 1;
      final newStart = int.parse(match[3]!);
      final newCount = match[4] != null ? int.parse(match[4]!) : 1;
      i++;
      final body = <String>[];
      var oldSeen = 0;
      var newSeen = 0;
      var malformed = false;
      while (oldSeen < oldCount || newSeen < newCount) {
        if (i >= lines.length) {
          malformed = true;
          break;
        }
        final line = lines[i];
        final kind = line.isEmpty ? ' ' : line[0];
        if (kind == '\\') {
          body.add(line);
          i++;
          continue;
        }
        if (kind != ' ' && kind != '-' && kind != '+') {
          malformed = true;
          break;
        }
        body.add(line);
        if (kind != '+') oldSeen++;
        if (kind != '-') newSeen++;
        i++;
      }
      if (malformed) return null;
      // A `\ No newline at end of file` marker can follow the last counted
      // body line.
      while (i < lines.length && lines[i].startsWith('\\')) {
        body.add(lines[i]);
        i++;
      }
      hunks.add(
        _PatchHunk(
          oldStart: oldStart,
          oldCount: oldCount,
          newStart: newStart,
          newCount: newCount,
          body: body,
        ),
      );
    }
    files.add(_PatchFile(oldName: oldName, newName: newName, hunks: hunks));
  }
  return files;
}

/// Extracts the file name from a `---`/`+++` header line, dropping a
/// tab-separated timestamp when present.
String _patchFileName(String header) {
  final tab = header.indexOf('\t');
  return (tab >= 0 ? header.substring(0, tab) : header).trim();
}

/// Applies the `-p` strip level to [name]: removes [strip] leading path
/// components while preserving an absolute-path leading slash.
String _stripPath(String name, int strip) {
  final absolute = name.startsWith('/');
  final segments = name
      .split('/')
      .where((s) => s.isNotEmpty && s != '.')
      .toList();
  if (segments.length <= strip) return '';
  final stripped = segments.sublist(strip).join('/');
  return absolute ? '/$stripped' : stripped;
}

/// Applies [hunks] to [doc], searching for each hunk's position with a
/// growing offset from the header position (no fuzz). Failed hunks are
/// skipped and reported by 1-based number; the file content is left
/// partially patched in that case, and the caller decides not to write it.
({List<String> lines, bool trailingNewline, List<int> failures}) _applyHunks(
  _LineDoc doc,
  List<_PatchHunk> hunks,
) {
  final lines = [...doc.lines];
  var trailingNewline = doc.trailingNewline;
  final failures = <int>[];
  var shift = 0;
  for (var h = 0; h < hunks.length; h++) {
    final hunk = hunks[h];
    final oldPart = <String>[];
    final newPart = <String>[];
    var markerOld = false;
    var markerNew = false;
    String? previousKind;
    for (final bodyLine in hunk.body) {
      final kind = bodyLine.isEmpty ? ' ' : bodyLine[0];
      if (kind == '\\') {
        if (previousKind == '-') {
          markerOld = true;
        } else if (previousKind == '+') {
          markerNew = true;
        } else if (previousKind == ' ') {
          markerOld = true;
          markerNew = true;
        }
        continue;
      }
      final text = bodyLine.isEmpty ? '' : bodyLine.substring(1);
      if (kind != '+') oldPart.add(text);
      if (kind != '-') newPart.add(text);
      previousKind = kind;
    }
    final start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1;
    final position = _findHunkPosition(lines, oldPart, start + shift);
    if (position == null) {
      failures.add(h + 1);
      continue;
    }
    lines.replaceRange(position, position + oldPart.length, newPart);
    // Track the drift between original and current coordinates so later
    // hunk positions stay meaningful after inserts/deletes and offsets.
    shift = position + newPart.length - (start + hunk.oldCount);
    if (markerNew) trailingNewline = false;
    if (markerOld && !markerNew) trailingNewline = true;
  }
  return (lines: lines, trailingNewline: trailingNewline, failures: failures);
}

/// Finds the position where [oldPart] matches [lines], trying [expected]
/// first and then growing offsets in both directions (like GNU patch,
/// without fuzz). Returns null when the hunk applies nowhere.
int? _findHunkPosition(List<String> lines, List<String> oldPart, int expected) {
  bool matches(int position) {
    if (position < 0 || position + oldPart.length > lines.length) {
      return false;
    }
    for (var k = 0; k < oldPart.length; k++) {
      if (lines[position + k] != oldPart[k]) return false;
    }
    return true;
  }

  final limit = lines.length + expected.abs() + 1;
  for (var distance = 0; distance <= limit; distance++) {
    if (matches(expected + distance)) return expected + distance;
    if (distance > 0 && matches(expected - distance)) {
      return expected - distance;
    }
  }
  return null;
}

/// Joins [lines] back into file content, honoring [trailingNewline].
String _joinLines(List<String> lines, bool trailingNewline) {
  if (lines.isEmpty) return '';
  final joined = lines.map((line) => '$line\n').join();
  return trailingNewline ? joined : joined.substring(0, joined.length - 1);
}
