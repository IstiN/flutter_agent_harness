/// Per-provider proxy configuration (issue #1921): a provider's
/// `network:` block in `~/.fah/config.yaml` binds every HTTP request of
/// that provider — unary, SSE, retries, model-list, quota — to a proxy.
///
/// This file is the PURE half of the abstraction (no `dart:io`): the
/// config model with strict validation, the route decision table, the
/// [ProxyConnector] interface, and the fail-closed client wrapper. The
/// `dart:io` connector implementations live in `proxy_connector_io.dart`
/// (exported from `lib/io.dart`).
///
/// Fail-closed invariant: when a `network:` block is bound, there is no
/// direct-egress fallback — every transport failure surfaces as a provider
/// error event naming the config keys. No block at all means
/// byte-identical legacy behavior (the client stays null and adapters use
/// the shared direct client).
library;

import 'package:http/http.dart' as http;

import '../exceptions.dart';

/// The `network:` block of one provider.
///
/// ```yaml
/// providers:
///   kimi_me:
///     network:
///       proxy: socks5://127.0.0.1:1080   # or http://… / https://…
///       proxyUsername: user              # optional
///       proxyPasswordEnv: KIMI_PROXY_PASSWORD  # secret by env reference ONLY
/// ```
///
/// Parsing is strict (bad config must surface, never silently degrade to
/// direct egress): unknown fields, inline credentials (`user:pass@host`),
/// and unsupported schemes throw [ConfigException].
final class ProviderNetworkConfig {
  const ProviderNetworkConfig({
    required this.proxy,
    this.proxyUsername,
    this.proxyPasswordEnv,
    this.label = 'network',
  });

  /// The yaml keys a `network:` block accepts (unknown-field rejection).
  static const allowedKeys = {'proxy', 'proxyUsername', 'proxyPasswordEnv'};

  /// Proxy schemes accepted in v1 (RFC9110 CONNECT via dart:io's native
  /// proxy support for http/https; RFC1928 + RFC1929 for socks5).
  static const allowedSchemes = {'http', 'https', 'socks5'};

  /// Parses one `network:` yaml map. [configLabel] names the owning
  /// provider in error text (e.g. `providers.kimi_me`).
  factory ProviderNetworkConfig.fromYaml(
    Object? node, {
    String configLabel = 'network',
  }) {
    if (node is! Map) {
      throw ConfigException('$configLabel must be a map, got: $node');
    }
    final allowed = allowedKeys.toList()..sort();
    for (final key in node.keys) {
      if (!allowedKeys.contains('$key')) {
        throw ConfigException(
          '$configLabel: unknown key "$key" (allowed: ${allowed.join(', ')})',
        );
      }
    }
    final rawProxy = node['proxy'];
    if (rawProxy is! String || rawProxy.trim().isEmpty) {
      throw ConfigException('$configLabel needs a non-empty "proxy" URL');
    }
    final uri = Uri.tryParse(rawProxy.trim());
    if (uri == null || !allowedSchemes.contains(uri.scheme.toLowerCase())) {
      final schemes = allowedSchemes.toList()..sort();
      throw ConfigException(
        '$configLabel: proxy must use one of ${schemes.join(' / ')} '
        '(got: "$rawProxy")',
      );
    }
    // Secrets never ride the URL: `user:pass@host` is rejected so the
    // credential cannot leak through logs, trajectory, or the config echo.
    if (uri.userInfo.isNotEmpty) {
      throw ConfigException(
        '$configLabel: inline proxy credentials are not allowed — move them '
        'to "proxyUsername" and "proxyPasswordEnv" (the password is resolved '
        'from the environment, never stored in the config)',
      );
    }
    if (uri.host.isEmpty) {
      throw ConfigException(
        '$configLabel: proxy URL needs a host (got: "$rawProxy")',
      );
    }

    String? requireString(Object? value, String field) {
      if (value == null) return null;
      if (value is! String || value.trim().isEmpty) {
        throw ConfigException(
          '$configLabel: "$field" must be a non-empty string',
        );
      }
      return value.trim();
    }

    final username = requireString(node['proxyUsername'], 'proxyUsername');
    final passwordEnv = requireString(
      node['proxyPasswordEnv'],
      'proxyPasswordEnv',
    );
    if (username != null && passwordEnv == null) {
      throw ConfigException(
        '$configLabel: "proxyUsername" without "proxyPasswordEnv" — the '
        'password must be referenced by env name, never inline',
      );
    }
    // The mirror direction is dead config, not a partial feature: both
    // HTTP Basic and RFC1929 need user AND password, so a passwordEnv
    // without a username would silently never be sent. Fail loudly.
    if (passwordEnv != null && username == null) {
      throw ConfigException(
        '$configLabel: "proxyPasswordEnv" without "proxyUsername" — the '
        'proxy credential needs both halves (HTTP Basic / RFC1929 '
        'user+pass); set proxyUsername next to proxyPasswordEnv',
      );
    }
    if (uri.port != 0 && (uri.port < 1 || uri.port > 65535)) {
      throw ConfigException(
        '$configLabel: proxy port ${uri.port} out of range 1..65535',
      );
    }
    return ProviderNetworkConfig(
      proxy: uri,
      proxyUsername: username,
      proxyPasswordEnv: passwordEnv,
      label: configLabel,
    );
  }

  /// The validated proxy URL (http / https / socks5, no credentials).
  final Uri proxy;

  /// Optional proxy username (SOCKS5 RFC1929 / HTTP Basic).
  final String? proxyUsername;

  /// The env var name holding the proxy password — reference only, the
  /// value never appears in the config.
  final String? proxyPasswordEnv;

  /// The owning provider's config label, carried into error text.
  final String label;

  String get scheme => proxy.scheme.toLowerCase();

  /// Resolves the proxy password through [lookup] (the environment).
  ///
  /// A configured [proxyPasswordEnv] whose variable is unset throws with
  /// the actionable text naming `request_secret` (AC1): the run must not
  /// silently fall back to direct egress. Null when no password is
  /// configured.
  String? resolvePasswordVia(String? Function(String name) lookup) {
    final name = proxyPasswordEnv;
    if (name == null) return null;
    final value = lookup(name);
    if (value == null || value.isEmpty) {
      throw ConfigException(
        'Proxy for "$label" needs the password in env var $name '
        '(proxyPasswordEnv), but it is not set. Set it before starting, or '
        'grant it at runtime via the request_secret tool — direct egress is '
        'disabled (fail-closed).',
      );
    }
    return value;
  }
}

/// The resolved proxy endpoint coordinates (host + port).
typedef ProxyRoute = ({String host, int port});

/// The route decision table: scheme → endpoint the io connector dials.
///
/// Default ports when the URL omits one: http → 80, https → 443,
/// socks5 → 1080 (the standard SOCKS port).
ProxyRoute proxyRoute(ProviderNetworkConfig config) {
  final host = config.proxy.host;
  final port = config.proxy.port;
  if (port != 0) return (host: host, port: port);
  return switch (config.scheme) {
    'http' => (host: host, port: 80),
    'https' => (host: host, port: 443),
    _ => (host: host, port: 1080), // socks5
  };
}

/// Produces the [http.Client] a bound provider's adapters run on.
///
/// Pure interface — implementations are `dart:io`-backed and live in
/// `lib/io.dart` ([ioProxyConnector]). Tests inject fakes.
abstract interface class ProxyConnector {
  http.Client createClient();
}

/// The fail-closed error text for a proxied provider failure (the card's
/// exact contract): names the provider, the reason, and the config keys.
String proxyFailureText(String providerName, String reason) =>
    "Proxy for provider '$providerName' failed: $reason. Direct egress is "
    'disabled (fail-closed). Check network.proxy / proxyPasswordEnv.';

/// One-line summary of a transport error (SocketException texts are
/// multi-line; transcripts want one line).
String proxyReasonOf(Object error) =>
    error.toString().replaceAll('\n', ' ').trim();

/// An [http.Client] that turns EVERY transport failure of the proxied
/// inner client into an actionable fail-closed [http.ClientException]
/// ([proxyFailureText] — `http.ClientException.message` is what
/// `formatProviderError` renders, so the text lands in the error event).
///
/// Mid-stream drops are covered too: the response body stream's errors are
/// remapped, so an SSE consumer sees the same actionable text (E1).
/// Unbound providers never see this wrapper — the direct path stays
/// byte-identical.
final class FailClosedProxyClient extends http.BaseClient {
  FailClosedProxyClient(
    this._inner,
    this.providerName, {
    this.onClose,
    Future<void>? ready,
  }) : _ready = ready ?? Future.value();

  final http.Client _inner;
  final String providerName;

  /// Runs when this client closes (e.g. the SOCKS5 relay's listener
  /// shutdown).
  final void Function()? onClose;

  final Future<void> _ready;

  /// Completes once the underlying stack can serve requests (a connector
  /// with async setup — the SOCKS5 relay bind — gates the first send on
  /// it so no request ever races the setup).
  Future<void> get ready => _ready;

  http.ClientException _failure(Object error) => http.ClientException(
    proxyFailureText(providerName, proxyReasonOf(error)),
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await _ready;
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } on Object catch (error) {
      throw _failure(error);
    }
    // Remap mid-stream body errors (proxy killed while SSE is flowing).
    return http.StreamedResponse(
      response.stream.handleError(
        (Object error, StackTrace stackTrace) => throw _failure(error),
      ),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    _inner.close();
    onClose?.call();
  }
}
