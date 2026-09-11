// VM stand-in for the fetch client: the extension never runs on the VM,
// but the pure provider registry is unit-tested there (dart test).
library;

import 'package:http/http.dart' as http;

/// Never instantiated on the web build path; exists to satisfy imports.
final class FetchClient extends http.BaseClient {
  /// Mirrors the web signature (the credentials mode is fetch-only).
  FetchClient({this.credentials = 'include'});

  /// Ignored on the VM (see the web implementation).
  final String credentials;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw UnsupportedError(
        'FetchClient is web-only; tests must not make network calls',
      );
}
