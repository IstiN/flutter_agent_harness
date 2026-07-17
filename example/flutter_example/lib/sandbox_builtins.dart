// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

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

/// Dart-native implementations of `curl`, `wget`, `jq`, and `yq` shared by
/// the WASM shell (iOS/Android) and the in-memory web shell.
///
/// These are pure Dart (no `dart:io`) so they compile for the browser; each
/// shell injects its own filesystem access through [SandboxTextReader] and
/// [SandboxBytesWriter], and HTTP goes through an injectable [http.Client]
/// so tests can use `MockClient` from `package:http/testing.dart`.
final class SandboxBuiltins {
  /// Creates the builtins over the injected filesystem and HTTP client.
  SandboxBuiltins({
    http.Client? httpClient,
    required this.readTextFile,
    required this.writeBinaryFile,
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  /// Injected text-file reader; see [SandboxTextReader].
  final SandboxTextReader readTextFile;

  /// Injected binary-file writer; see [SandboxBytesWriter].
  final SandboxBytesWriter writeBinaryFile;

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
}
