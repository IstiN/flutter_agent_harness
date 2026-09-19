/// The web-egress network gate (issue #682): a cube's `spec.network`
/// policy becomes an actual boundary for the run's web tools, not a
/// lexical hint about `curl` arguments.
///
/// [CubeNetworkGate] is the pure decision — `(Uri) → allowed` over the
/// LIVE [CubeSpec] (read per call, so `/cube use`/`/cube off` mid-session
/// are honored by the next call). [GatedHttpClient] wraps the web tools'
/// injectable `package:http` client so no byte leaves without a pass.
///
/// Semantics (same matching rules as `config/network_policy.dart`):
/// exact host (case-insensitive), `*`, `*.domain` (apex + subdomains,
/// never `notexample.com`), IP literals exact; ports from the rule or the
/// scheme default (`http` 80 / `https` 443). A denial is a normal tool
/// result (`fa_cube[<name>]: network …` note), never a provider error.
///
/// Hosts without cube support pass `networkGate: null`: the tools skip
/// the wrapper entirely and runs stay byte-identical (kill-switch, same
/// shape as `images.registry: false`). Operator-configured egress
/// (model-provider calls, media slots) is exempt by design — gating the
/// provider would kill the run; the provider is the operator's trust
/// decision.
library;

import 'package:http/http.dart' as http;

import 'config/cube_spec.dart';

/// Thrown by [GatedHttpClient] when a request — or a redirect hop —
/// targets a destination the active cube's network policy denies. The web
/// tools catch it and answer with the note as a normal tool result.
final class CubeNetworkDeniedException implements Exception {
  /// Creates the exception carrying the user-facing denial note.
  const CubeNetworkDeniedException(this.message);

  /// The `fa_cube[<name>]:` note (host and port only — never userinfo).
  final String message;

  @override
  String toString() => message;
}

/// Decides whether a URL may be fetched under the live cube policy.
final class CubeNetworkGate {
  /// Creates a gate reading [spec] on every decision. A `null` result —
  /// no cube active — is allow-all.
  const CubeNetworkGate(this.spec);

  /// The live cube spec source (`null` = no cube, allow-all).
  final CubeSpec? Function() spec;

  /// The denial note for [uri], or `null` when the gate allows it.
  ///
  /// The port falls back to the scheme default (`http` 80, `https` 443),
  /// so `http://` against a `ports: [443]` rule is denied. Matching runs
  /// on the host alone — userinfo (`user:pass@`) and the path never reach
  /// a rule or a note.
  String? denialFor(Uri uri) {
    final active = spec();
    if (active == null) return null;
    final host = uri.host;
    final port = uri.port;
    if (active.network.permits(host, port)) return null;
    return "fa_cube[${active.name}]: network access to '$host:$port' "
        "denied by cube '${active.name}'";
  }

  /// Whether [uri] may be reached.
  bool allows(Uri uri) => denialFor(uri) == null;

  /// Throws [CubeNetworkDeniedException] when [uri] is denied.
  void check(Uri uri) {
    final denial = denialFor(uri);
    if (denial != null) throw CubeNetworkDeniedException(denial);
  }
}

/// An [http.Client] enforcing a [CubeNetworkGate] before every request
/// leaves the process (defense in depth behind the tools' pre-checks).
///
/// E1 (pinned): the gate re-checks EVERY redirect hop. Auto-follow is
/// disabled at the gate level and hops are followed here — each target is
/// checked before its socket opens, so an allowed host cannot bounce a
/// request to a denied one. Cross-host hops drop `authorization`/`cookie`
/// headers; the hop ceiling mirrors `loadWebPage`'s five.
final class GatedHttpClient extends http.BaseClient {
  /// Wraps [inner]; every request and redirect target passes [gate].
  GatedHttpClient(this._inner, this._gate);

  final http.Client _inner;
  final CubeNetworkGate _gate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _gate.check(request.url);
    // Snap the body before the inner send finalizes the request, so a
    // 307/308 hop can replay it.
    final body = request is http.Request ? request.bodyBytes : null;
    for (var hop = 0; ; hop++) {
      request.followRedirects = false;
      final response = await _inner.send(request);
      final location = _redirectLocation(response);
      if (location == null) return response;
      // Drain the redirect body before opening the next hop.
      await response.stream.drain<void>();
      if (hop >= _maxRedirects) {
        throw http.ClientException('Redirect limit exceeded', request.url);
      }
      final target = request.url.resolve(location);
      _gate.check(target);
      request = _hopRequest(request, response.statusCode, target, body);
    }
  }

  /// The Location of a redirect response, or `null` when [response] is
  /// terminal (or its Location is unusable — then it surfaces as-is).
  static String? _redirectLocation(http.StreamedResponse response) =>
      switch (response.statusCode) {
        301 || 302 || 303 || 307 || 308 => response.headers['location'],
        _ => null,
      };

  static const _maxRedirects = 5;

  /// Builds the next-hop request: 301/302/303 replay as GET (body
  /// dropped), 307/308 keep method and body. Credential headers only
  /// follow same-host hops.
  http.Request _hopRequest(
    http.BaseRequest previous,
    int statusCode,
    Uri target,
    List<int>? body,
  ) {
    final redirected =
        statusCode == 301 || statusCode == 302 || statusCode == 303;
    final method = redirected ? 'GET' : previous.method;
    final hop = http.Request(method, target)
      ..followRedirects = false
      ..headers.addAll(previous.headers);
    if (target.host != previous.url.host ||
        target.scheme != previous.url.scheme) {
      hop.headers.removeWhere(
        (name, _) =>
            name.toLowerCase() == 'authorization' ||
            name.toLowerCase() == 'cookie',
      );
    }
    if (!redirected && body != null && body.isNotEmpty) {
      hop.bodyBytes = body;
    }
    return hop;
  }
}
