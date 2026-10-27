/// `dart:io` [ProxyConnector] implementations (issue #1921): the HTTP
/// CONNECT and SOCKS5 clients a bound provider's adapters run on.
///
/// Import only from platform code allowed to touch `dart:io` (the CLI
/// gate, tests); the pure half lives in `proxy_connector.dart` and the
/// core library never imports this file.
///
/// Wire shape per scheme:
/// - `http://`  — dart:io native CONNECT (`HttpClient.findProxy` →
///   `PROXY host:port`); proxy auth rides the native 407 →
///   `authenticateProxy` → `addProxyCredentials` retry.
/// - `https://` — same native CONNECT machinery over a TLS transport to
///   the proxy, supplied through `HttpClient.connectionFactory` (dart:io
///   runs CONNECT and the target TLS handshake over the returned socket).
/// - `socks5://` — dart:io has no SOCKS support, and a
///   handshake-then-handoff connector is impossible on dart:io's public
///   API: the http layer listens the factory-returned socket's stream,
///   and a dart:io socket stream can never be re-listened after cancel.
///   Instead the connector spins a loopback CONNECT→SOCKS5 relay
///   ([_ProxyRelay]): dart:io speaks native CONNECT to
///   `127.0.0.1:<ephemeral>` and the relay performs the RFC1928 CONNECT
///   (remote DNS — the target hostname is sent UNRESOLVED) with RFC1929
///   username/password auth on outbound sockets it owns end-to-end.
///   `socks5://` means remote resolution in v1 — no local-resolve variant.
///
/// Every [ProxyConnector.createClient] returns a
/// [FailClosedProxyClient]: transport failures surface as the actionable
/// error event text, never as direct-egress retries.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;

import 'proxy_connector.dart';

/// Builds the [ProxyConnector] for [config]'s `network:` block.
///
/// [onBadCertificate] overrides TLS certificate validation for the proxy
/// transport (https:// proxy URLs) and for the target TLS leg — null
/// keeps the platform default (self-signed corporate proxies fail
/// closed). [environment] overrides the password-variable lookup
/// (Platform.environment by default; a test seam). No config key exposes
/// either.
ProxyConnector ioProxyConnector(
  ProviderNetworkConfig config, {
  bool Function(X509Certificate certificate)? onBadCertificate,
  Map<String, String>? environment,
  String? providerName,
}) {
  final route = proxyRoute(config);
  // The fail-closed error text names the PROVIDER (the card contract),
  // not the config label.
  final label = providerName ?? config.label;
  return switch (config.scheme) {
    'socks5' => _Socks5ProxyConnector(
      config,
      label,
      route,
      onBadCertificate,
      environment,
    ),
    'https' => _HttpsProxyConnector(
      config,
      label,
      route,
      onBadCertificate,
      environment,
    ),
    _ => _HttpProxyConnector(
      config,
      label,
      route,
      onBadCertificate,
      environment,
    ),
  };
}

/// `host:port` with IPv6 literals re-bracketed for the findProxy string.
String _authority(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

HttpClient _clientFor(String Function(Uri) findProxy) => HttpClient()
  ..findProxy = findProxy
  // A bound provider's egress ALWAYS rides the configured route — proxy
  // environment variables (HTTP_PROXY/HTTPS_PROXY) must not hijack it.
  ..autoUncompress = false;

/// Wires HTTP Basic proxy credentials into dart:io's native 407-retry:
/// the first CONNECT goes credential-less, and on a 407 challenge the
/// callback registers the credentials for the observed realm and returns
/// true so dart:io replays the CONNECT with `Proxy-Authorization: Basic …`.
///
/// The retry arms ONCE: a second 407 means the credentials are wrong
/// (they are static env values), and answering true again would ping-pong
/// the challenge forever — dart:io has no auth-retry budget. Returning
/// false completes the tunnel with the original 407, which the
/// fail-closed wrapper turns into the actionable error.
void _wireProxyBasicAuth(
  HttpClient client,
  ProviderNetworkConfig config,
  Map<String, String>? environment,
) {
  final username = config.proxyUsername;
  if (username == null) return;
  final password =
      config.resolvePasswordVia(
        (name) => (environment ?? Platform.environment)[name],
      ) ??
      '';
  var retried = false;
  client.authenticateProxy = (host, port, scheme, realm) async {
    if (retried) return false;
    retried = true;
    client.addProxyCredentials(
      host,
      port,
      realm ?? '',
      HttpClientBasicCredentials(username, password),
    );
    return true;
  };
}

void _wireBadCertificate(
  HttpClient client,
  bool Function(X509Certificate)? onBadCertificate,
) {
  if (onBadCertificate == null) return;
  client.badCertificateCallback = (cert, host, port) => onBadCertificate(cert);
}

/// `http://` proxy: pure native dart:io CONNECT — no custom sockets.
final class _HttpProxyConnector implements ProxyConnector {
  _HttpProxyConnector(
    this._config,
    this._label,
    this._route,
    this._onBadCertificate,
    this._environment,
  );

  final ProviderNetworkConfig _config;
  final String _label;
  final ProxyRoute _route;
  final bool Function(X509Certificate)? _onBadCertificate;
  final Map<String, String>? _environment;

  @override
  http.Client createClient() {
    // Resolving the password here (not lazily per request) keeps the
    // missing-env failure at bind time: fail-closed before any egress.
    _config.resolvePasswordVia(
      (name) => (_environment ?? Platform.environment)[name],
    );
    final client = _clientFor(
      (_) => 'PROXY ${_authority(_route.host, _route.port)}',
    );
    _wireBadCertificate(client, _onBadCertificate);
    _wireProxyBasicAuth(client, _config, _environment);
    return FailClosedProxyClient(IOClient(client), _label);
  }
}

/// `https://` proxy: native CONNECT over a TLS transport to the proxy.
final class _HttpsProxyConnector implements ProxyConnector {
  _HttpsProxyConnector(
    this._config,
    this._label,
    this._route,
    this._onBadCertificate,
    this._environment,
  );

  final ProviderNetworkConfig _config;
  final String _label;
  final ProxyRoute _route;
  final bool Function(X509Certificate)? _onBadCertificate;
  final Map<String, String>? _environment;

  @override
  http.Client createClient() {
    _config.resolvePasswordVia(
      (name) => (_environment ?? Platform.environment)[name],
    );
    final client = _clientFor(
      (_) => 'PROXY ${_authority(_route.host, _route.port)}',
    );
    _wireBadCertificate(client, _onBadCertificate);
    _wireProxyBasicAuth(client, _config, _environment);
    // dart:io runs the CONNECT handshake (and 407 retries) over the
    // socket returned here; only the transport to the proxy is custom.
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final socket = await SecureSocket.connect(
        proxyHost ?? _route.host,
        proxyPort ?? _route.port,
        onBadCertificate: _onBadCertificate,
      );
      return ConnectionTask.fromSocket(Future.value(socket), socket.destroy);
    };
    return FailClosedProxyClient(IOClient(client), _label);
  }
}

/// `socks5://` proxy: loopback CONNECT→SOCKS5 relay (see the library
/// comment for why the handshake cannot ride the http-layer socket).
final class _Socks5ProxyConnector implements ProxyConnector {
  _Socks5ProxyConnector(
    this._config,
    this._label,
    this._route,
    this._onBadCertificate,
    this._environment,
  );

  final ProviderNetworkConfig _config;
  final String _label;
  final ProxyRoute _route;
  final bool Function(X509Certificate)? _onBadCertificate;
  final Map<String, String>? _environment;

  @override
  http.Client createClient() {
    final password = _config.resolvePasswordVia(
      (name) => (_environment ?? Platform.environment)[name],
    );
    final relay = _ProxyRelay(
      route: _route,
      username: _config.proxyUsername,
      password: password,
    );
    final client = _clientFor(
      (_) => 'PROXY ${_authority(relay.host, relay.port)}',
    );
    // The target TLS leg of a proxied https request runs inside dart:io
    // (createProxyTunnel) and honors the client-level callback.
    _wireBadCertificate(client, _onBadCertificate);
    return FailClosedProxyClient(
      IOClient(client),
      _label,
      onClose: relay.close,
      ready: relay.bound,
    );
  }
}

/// RFC1928 reply-code → human text (RFC1962 errata: the through-proxy
/// qualifiers keep the operator pointed at the PROXY, not the target).
const _socks5ReplyTexts = <int, String>{
  0x01: 'general SOCKS server failure',
  0x02: 'connection not allowed by ruleset',
  0x03: 'network unreachable (through proxy)',
  0x04: 'host unreachable (through proxy)',
  0x05: 'connection refused (through proxy)',
  0x06: 'TTL expired (through proxy)',
  0x07: 'command not supported',
  0x08: 'address type not supported',
};

/// The RFC1928 reply code's text, or a hex render of an unknown code.
String socks5ReplyText(int code) =>
    _socks5ReplyTexts[code] ?? 'reply code 0x${code.toRadixString(16)}';

/// Exact-byte reader over a SOCKS5 handshake socket owned end-to-end by
/// the connector. The underlying [iterator] stays attached for the
/// post-handshake pipe ([leftover] flushes first) — a dart:io socket
/// stream can never be listened twice, so the reader and the pipe MUST
/// share it.
final class Socks5HandshakeReader {
  Socks5HandshakeReader(Socket socket)
    : _write = socket.add,
      iterator = StreamIterator(socket);

  /// Scripted constructor: reads ride [bytes], writes land in [sink] —
  /// the unit suite drives full handshakes with no sockets.
  Socks5HandshakeReader.scripted(Stream<Uint8List> bytes, this._write)
    : iterator = StreamIterator(bytes);

  final void Function(List<int> bytes) _write;

  final StreamIterator<Uint8List> iterator;

  /// The write side (the handshake socket's add in production).
  void add(List<int> bytes) => _write(bytes);
  Uint8List _buffer = Uint8List(0);

  /// Unread buffered bytes (early target data racing the handshake tail).
  Uint8List get leftover => _buffer;

  Future<Uint8List> readExactly(int count) async {
    while (_buffer.length < count) {
      if (!await iterator.moveNext()) {
        throw const SocketException(
          'SOCKS5 proxy closed the connection during the handshake',
        );
      }
      final chunk = iterator.current;
      final merged = Uint8List(_buffer.length + chunk.length)
        ..setRange(0, _buffer.length, _buffer)
        ..setRange(_buffer.length, _buffer.length + chunk.length, chunk);
      _buffer = merged;
    }
    final out = Uint8List.sublistView(_buffer, 0, count);
    _buffer = Uint8List.sublistView(_buffer, count);
    return out;
  }
}

/// The greeting offering [username]'s presence: version 5, methods
/// [no-auth] (+ [user/pass] when credentials are configured).
List<int> socks5GreetingBytes({required bool useAuth}) => [
  0x05,
  useAuth ? 2 : 1,
  0x00,
  if (useAuth) 0x02,
];

/// Negotiates the method-selection + optional RFC1929 user/pass leg
/// against [reader], writing through [sink]. Public and socket-free so
/// the unit suite drives it with a scripted byte stream.
Future<void> socks5NegotiateAuth(
  Socks5HandshakeReader reader,
  void Function(List<int> bytes) sink, {
  String? username,
  String? password,
}) async {
  final useAuth = username != null;
  sink(socks5GreetingBytes(useAuth: useAuth));
  final greeting = await reader.readExactly(2);
  if (greeting[0] != 0x05) {
    throw const SocketException('SOCKS5 proxy sent a non-v5 greeting');
  }
  switch (greeting[1]) {
    case 0x00:
      break;
    case 0x02 when useAuth:
      sink(_rfc1929AuthBytes(username: username, password: password));
      final verdict = await reader.readExactly(2);
      if (verdict[1] != 0x00) {
        throw const SocketException(
          'SOCKS5 username/password authentication failed (RFC1929 status '
          'non-zero) — check proxyUsername / proxyPasswordEnv',
        );
      }
    case 0xFF:
      throw const SocketException(
        'SOCKS5 proxy rejected every offered auth method',
      );
    default:
      throw SocketException(
        'SOCKS5 proxy chose unsupported auth method 0x'
        '${greeting[1].toRadixString(16)}',
      );
  }
}

/// The RFC1929 subnegotiation: ver 1, ulen user, plen pass.
List<int> _rfc1929AuthBytes({
  required String username,
  required String? password,
}) {
  final user = ascii.encode(username);
  final pass = ascii.encode(password ?? '');
  return [0x01, user.length, ...user, pass.length, ...pass];
}

/// The CONNECT request for `targetHost:targetPort`: the hostname rides
/// UNRESOLVED (ATYP 0x03, remote DNS at the proxy) unless it is already
/// an IP literal (ATYP 0x01/0x04).
List<int> socks5ConnectRequestBytes(String targetHost, int targetPort) {
  final address = InternetAddress.tryParse(targetHost);
  return [
    0x05,
    0x01, // CONNECT
    0x00,
    if (address != null)
      if (address.type == InternetAddressType.IPv4) ...[
        0x01,
        ...address.rawAddress,
      ] else ...[
        0x04,
        ...address.rawAddress,
      ]
    else ...[0x03, targetHost.length, ...ascii.encode(targetHost)],
    targetPort >> 8,
    targetPort & 0xFF,
  ];
}

/// Consumes the CONNECT reply (VER REP RSV ATYP BND.ADDR BND.PORT):
/// throws on a malformed VER, a failure REP, or an unknown ATYP.
Future<void> socks5ConsumeReply(Socks5HandshakeReader reader) async {
  final head = await reader.readExactly(4);
  if (head[0] != 0x05) {
    throw const SocketException('SOCKS5 proxy sent a malformed reply');
  }
  if (head[1] != 0x00) {
    throw SocketException('SOCKS5 CONNECT failed: ${socks5ReplyText(head[1])}');
  }
  var remaining = switch (head[3]) {
    0x01 => 4 + 2,
    0x04 => 16 + 2,
    0x03 => -1, // sized by the name-length byte, read below
    _ => throw SocketException(
      'SOCKS5 proxy replied with unknown address type 0x'
      '${head[3].toRadixString(16)}',
    ),
  };
  if (remaining < 0) {
    remaining = (await reader.readExactly(1))[0] + 2;
  }
  if (remaining > 0) {
    await reader.readExactly(remaining);
  }
}

/// Performs the full SOCKS5 handshake via [reader] and binds its socket
/// to `targetHost:targetPort`. The hostname is sent UNRESOLVED
/// (ATYP 0x03) unless it is already an IP literal (ATYP 0x01/0x04).
Future<void> socks5Bind(
  Socks5HandshakeReader reader,
  String targetHost,
  int targetPort, {
  String? username,
  String? password,
}) async {
  await socks5NegotiateAuth(
    reader,
    reader.add,
    username: username,
    password: password,
  );
  reader.add(socks5ConnectRequestBytes(targetHost, targetPort));
  await socks5ConsumeReply(reader);
}

/// The request-line target of a CONNECT (an authority) — its second
/// space-separated token, or '' when malformed.
String _connectAuthority(String requestLine) {
  final parts = requestLine.split(' ');
  return parts.length > 1 ? parts[1] : '';
}

/// The absolute-form http(s) target of a plain proxied request line, or
/// null when the line does not carry a parseable absolute URL.
(String, int)? _absoluteFormTarget(String requestLine) {
  final parts = requestLine.split(' ');
  if (parts.length < 2) return null;
  final uri = Uri.tryParse(parts[1]);
  if (uri == null || uri.host.isEmpty) return null;
  return (uri.host, uri.port == 0 ? 80 : uri.port);
}

/// The authority (host[:port]) of the request head's Host header, or ''
/// when the head carries none.
String _hostHeaderAuthority(String head) {
  final hostLine = head
      .split('\r\n')
      .skip(1)
      .firstWhere(
        (line) => line.toLowerCase().startsWith('host:'),
        orElse: () => '',
      );
  if (hostLine.isEmpty) return '';
  return hostLine.substring(hostLine.indexOf(':') + 1).trim();
}

/// Strips the [brackets] of an IPv6 literal.
String _unwrapIpv6(String rawHost) =>
    rawHost.startsWith('[') && rawHost.endsWith(']')
    ? rawHost.substring(1, rawHost.length - 1)
    : rawHost;

/// Splits an authority into host + port (defaulting to [fallbackPort]
/// when the port text is empty). Throws [SocketException] on an
/// unparsable authority; the host part keeps IPv6 brackets stripped.
(String, int) _splitAuthority(
  String authority,
  String requestLine, {
  required int fallbackPort,
}) {
  final colon = authority.lastIndexOf(':');
  if (colon <= 0) {
    throw SocketException('relay inbound named no target: $requestLine');
  }
  final rawHost = authority.substring(0, colon);
  final portText = authority.substring(colon + 1);
  final port = portText.isEmpty ? fallbackPort : int.tryParse(portText);
  if (port == null) {
    throw SocketException('relay inbound named a bad port: $requestLine');
  }
  return (_unwrapIpv6(rawHost), port);
}

/// CONNECT host:port from the request line, else the Host header — the
/// relay target every accepted inbound is bound through. Public and
/// socket-free so the unit suite drives the parse paths directly.
(String, int) relayTargetOf(String requestLine, String head) {
  if (requestLine.startsWith('CONNECT')) {
    // CONNECT carries no scheme — the tunnel target is https by
    // convention; an explicit port in the authority wins.
    return _splitAuthority(
      _connectAuthority(requestLine),
      requestLine,
      fallbackPort: 443,
    );
  }
  final absolute = _absoluteFormTarget(requestLine);
  if (absolute != null) return absolute;
  // Plain origin-form fell through to the Host header: http's default.
  return _splitAuthority(
    _hostHeaderAuthority(head),
    requestLine,
    fallbackPort: 80,
  );
}

/// The loopback CONNECT→SOCKS5 relay: dart:io's native CONNECT machinery
/// dials loopback [host]/[port]; every accepted connection is bound to
/// its request target through the SOCKS5 proxy (CONNECT tunnels), or —
/// for plain-HTTP absolute-form requests — piped after the first request
/// head names the target.
final class _ProxyRelay {
  _ProxyRelay({required this.route, this.username, this.password}) {
    _bound = ServerSocket.bind(InternetAddress.loopbackIPv4, 0).then((server) {
      _server = server;
      server.listen(_accept, onError: (Object _) {});
    });
  }

  final ProxyRoute route;
  final String? username;
  final String? password;

  ServerSocket? _server;
  late Future<void> _bound;
  final Set<Socket> _tunnels = {};
  var _closed = false;

  /// Completes once the listener accepts connections (the provider
  /// client's first send gates on this).
  Future<void> get bound => _bound;

  /// Relay coordinates — read only from the findProxy callback, which
  /// fires after [bound] completed.
  String get host => _server?.address.address ?? '127.0.0.1';

  int get port => _server?.port ?? 0;

  void _accept(Socket inbound) {
    _tunnels.add(inbound);
    // The serve error is already answered on the wire (502 / destroy);
    // every derived future must be suppressed or the zone sees it twice.
    final served = _serve(inbound);
    served.ignore();
    served.whenComplete(() => _tunnels.remove(inbound)).ignore();
  }

  Future<void> _serve(Socket inbound) async {
    final iterator = StreamIterator<Uint8List>(inbound);
    var headServed = false;
    try {
      final head = await _readRequestHead(iterator);
      headServed = true;
      final requestLine = head.split('\r\n').first;
      final (targetHost, targetPort) = _targetOf(requestLine, head);
      final Socket outbound;
      final Socks5HandshakeReader reader;
      try {
        outbound = await Socket.connect(route.host, route.port);
        _tunnels.add(outbound);
        reader = Socks5HandshakeReader(outbound);
        await socks5Bind(
          reader,
          targetHost,
          targetPort,
          username: username,
          password: password,
        );
      } on Object {
        // The SOCKS5 leg never came up — answer dart:io's CONNECT with a
        // failure so the provider error names the proxy leg.
        if (requestLine.startsWith('CONNECT')) {
          _replyTunnelFailure(inbound);
        } else {
          inbound.destroy();
        }
        rethrow;
      }
      if (requestLine.startsWith('CONNECT')) {
        inbound.add(
          ascii.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
        );
      } else {
        // Plain-HTTP target: forward the request head verbatim
        // (absolute-form targets are RFC-compliant for origin servers)
        // and keep piping the rest of the connection.
        outbound.add(ascii.encode(head));
      }
      await outbound.flush();
      await Future.wait([
        _pipeFrom(iterator, outbound),
        _pipeSocksFrom(reader, inbound),
      ]);
      // Both directions ended — the tunnel is fully drained.
      inbound.destroy();
      outbound.destroy();
    } on Object {
      if (!_closed && !headServed) {
        // The request head never even arrived — nothing else to answer
        // with; drop the inbound socket.
        _replyTunnelFailure(inbound);
      }
      rethrow;
    }
  }

  /// Reads one HTTP request head (bounded) from the relay inbound
  /// socket. The iterator stays attached — [_pipeFrom] continues on it
  /// (a dart:io socket stream can never be listened twice).
  Future<String> _readRequestHead(StreamIterator<Uint8List> iterator) async {
    var total = 0;
    final seen = BytesBuilder(copy: false);
    while (true) {
      if (!await iterator.moveNext()) {
        throw const SocketException('relay inbound closed before a head');
      }
      seen.add(iterator.current);
      total += iterator.current.length;
      final text = latin1.decode(seen.takeBytes(), allowInvalid: true);
      final end = text.indexOf('\r\n\r\n');
      if (end >= 0) {
        return text.substring(0, end + 4);
      }
      if (total > 16384) {
        throw const SocketException('relay inbound head exceeded 16 KiB');
      }
    }
  }

  void _replyTunnelFailure(Socket inbound) {
    try {
      inbound.add(ascii.encode('HTTP/1.1 502 upstream proxy failure\r\n\r\n'));
      unawaited(inbound.flush().whenComplete(inbound.destroy));
    } on Object {
      inbound.destroy();
    }
  }

  /// CONNECT host:port from the request line, else the Host header.
  (String, int) _targetOf(String requestLine, String head) =>
      relayTargetOf(requestLine, head);

  /// Pipes the already-attached [iterator] into [to]. A clean end just
  /// stops piping — the socket pair is torn down by [_serve] once BOTH
  /// directions end (a destroy here would kill the response path of a
  /// still-open tunnel, and close()/shutdown semantics vary too much
  /// across dart:io versions to be safe). Flushes before returning so no
  /// buffered write is dropped.
  Future<void> _pipeFrom(StreamIterator<Uint8List> iterator, Socket to) async {
    try {
      while (await iterator.moveNext()) {
        to.add(iterator.current);
      }
      await to.flush();
    } on Object {
      to.destroy();
    }
  }

  /// The SOCKS5 outbound leg: flush the handshake reader's leftover
  /// bytes, then keep piping on the SAME iterator the handshake used.
  Future<void> _pipeSocksFrom(Socks5HandshakeReader reader, Socket to) async {
    if (reader.leftover.isNotEmpty) {
      to.add(reader.leftover);
    }
    await _pipeFrom(reader.iterator, to);
  }

  /// Stops accepting and tears down every open tunnel.
  Future<void> close() async {
    _closed = true;
    await _bound;
    await _server?.close();
    for (final tunnel in _tunnels.toList()) {
      tunnel.destroy();
    }
    _tunnels.clear();
  }
}
