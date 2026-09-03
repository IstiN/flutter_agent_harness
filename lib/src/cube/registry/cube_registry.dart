/// The fa1.dev cube registry client: a catalog of ready-made cube manifests
/// (`/cube templates`) and verified downloads into `.fah/cubes/`
/// (`/cube install`).
///
/// Pure Dart over injectable `package:http` (same pattern as the A2A
/// client), so unit tests run against `http.testing.MockClient` and web
/// builds reuse the shared client. Every failure — HTTP status, malformed
/// catalog, sha256 mismatch — surfaces as a [ConfigException]; the CLI
/// layer prints it as a line, never a crash.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../exceptions.dart';

/// One catalog entry of the cube registry.
final class CubeRegistryTemplate {
  /// Creates a template descriptor.
  const CubeRegistryTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.file,
    required this.sha256,
  });

  /// Parses one `templates[]` entry; strict — [where] names the offending
  /// entry in the error message.
  factory CubeRegistryTemplate.fromTemplateJson(
    Map<Object?, Object?> json, {
    required String where,
  }) {
    String required(String key) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      throw ConfigException(
        'cube registry: $where: "$key" must be a non-empty string',
      );
    }

    final sha = required('sha256');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw ConfigException(
        'cube registry: $where: "sha256" must be 64 hex chars, got "$sha"',
      );
    }
    return CubeRegistryTemplate(
      id: required('id'),
      name: required('name'),
      description: required('description'),
      file: required('file'),
      sha256: sha,
    );
  }

  /// Manifest id — also the file name used by `/cube install`
  /// (`<id>.yaml` under `.fah/cubes/`).
  final String id;

  /// Human title.
  final String name;

  /// One-line description.
  final String description;

  /// Manifest path relative to the registry's `/cubes/` root.
  final String file;

  /// sha256 hex of the manifest bytes — verified on download.
  final String sha256;
}

/// The cube registry client.
final class CubeRegistryClient {
  /// Creates a client against a registry base url (default: fa1.dev).
  CubeRegistryClient({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  /// The default registry base url.
  static const defaultBaseUrl = 'https://fa1.dev';

  /// The registry base url, e.g. `https://fa1.dev`.
  final String baseUrl;

  final http.Client _client;

  /// Fetches the catalog: `GET <baseUrl>/cubes/templates.json`.
  Future<List<CubeRegistryTemplate>> templates() async {
    final body = await _get(_catalogUrl());
    final Object? document;
    try {
      document = jsonDecode(body);
    } on FormatException catch (error) {
      throw ConfigException(
        'cube registry: invalid json in ${_catalogUrl()}: ${error.message}',
      );
    }
    if (document is! Map<Object?, Object?> ||
        document['templates'] is! List<Object?>) {
      throw ConfigException(
        'cube registry: ${_catalogUrl()} must be a json object with a '
        '"templates" list',
      );
    }
    final entries = document['templates']! as List<Object?>;
    return [
      for (final (index, entry) in entries.indexed)
        if (entry is Map<Object?, Object?>)
          CubeRegistryTemplate.fromTemplateJson(
            entry,
            where: 'templates[$index]',
          )
        else
          throw ConfigException(
            'cube registry: templates[$index] must be a json object',
          ),
    ];
  }

  /// Downloads [template]'s manifest from `<baseUrl>/cubes/<file>` and
  /// verifies its sha256 — a mismatch refuses the bytes.
  Future<String> download(CubeRegistryTemplate template) async {
    final url = '$baseUrl/cubes/${template.file}';
    final body = await _get(url);
    final actual = sha256.convert(utf8.encode(body)).toString();
    if (actual != template.sha256) {
      throw ConfigException(
        'cube registry: sha256 mismatch for ${template.id} ($url): '
        'expected ${template.sha256}, got $actual — refusing the manifest',
      );
    }
    return body;
  }

  String _catalogUrl() => '$baseUrl/cubes/templates.json';

  Future<String> _get(String url) async {
    final http.Response response;
    try {
      response = await _client.get(Uri.parse(url));
    } on http.ClientException catch (error) {
      throw ConfigException('cube registry: $url: ${error.message}');
    }
    if (response.statusCode != 200) {
      throw ConfigException(
        'cube registry: HTTP ${response.statusCode} from $url',
      );
    }
    return utf8.decode(response.bodyBytes);
  }
}
