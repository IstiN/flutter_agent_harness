// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Host side of the python HTTP bridge.
///
/// The bundled CPython-WASI build has no socket support and no `ssl` module,
/// so `urllib`/`http.client` cannot open network connections. The python side
/// (`fa_http.py`, materialized into site-packages by `WasiSandboxShell`)
/// patches `http.client` so every request is printed to stdout as a control
/// line and the interpreter then polls `/dev/.fahttp/<id>` for the raw
/// response. This class is the host half: it strips control lines from the
/// captured stdout, performs the request with the shell's own HTTP client
/// (which has real TLS and real network permission gates) and writes the
/// serialized response back into the sandbox filesystem.
///
/// Protocol (control line, stripped from the stage's stdout):
/// `\x01FAHTTP1 <rid> <authority> <base64-of-raw-request>\n`
///
/// The raw request is the exact HTTP/1.1 bytes `http.client` buffered
/// (request line + headers + body). The response file starts with `!` on
/// transport failure (message follows); otherwise it holds raw HTTP/1.1
/// response bytes that `http.client.HTTPResponse` parses normally.
final class FaHttpBridge {
  /// Creates a bridge writing responses under `<sandboxRoot>/dev/.fahttp`.
  FaHttpBridge({required String sandboxRoot, required http.Client httpClient})
    : _root = sandboxRoot,
      _httpClient = httpClient;

  static final RegExp _marker = RegExp(
    '\x01FAHTTP1 ([0-9a-f]{1,32}) ([^ ]{1,512}) ([A-Za-z0-9+/=]+)\n',
  );

  final String _root;
  final http.Client _httpClient;

  /// Bytes held back because they may be the start of a split control line.
  String _carry = '';

  /// Filters [chunk]: removes complete control lines (their requests are
  /// served in the background) and holds back a trailing partial line that
  /// could still grow into one. Input is treated as bytes (latin-1 round
  /// trip), so binary stdout passes through untouched.
  List<int> filter(List<int> chunk) {
    var text = _carry + latin1.decode(chunk);
    _carry = '';
    // Hold back a trailing fragment that could still grow into a control
    // line: from the last SOH byte to the end, whenever no newline follows
    // it (a complete control line always ends with one).
    final soh = text.lastIndexOf('\x01');
    if (soh != -1 && text.indexOf('\n', soh) == -1) {
      _carry = text.substring(soh);
      text = text.substring(0, soh);
    }
    if (!text.contains('\x01')) return latin1.encode(text);
    return latin1.encode(
      text.replaceAllMapped(_marker, (match) {
        _schedule(match[1]!, match[2]!, match[3]!);
        return '';
      }),
    );
  }

  /// Returns bytes held back for a possible control line that never
  /// completed (the stage ended); the captured stdout stays byte-faithful.
  List<int> flush() {
    final rest = _carry;
    _carry = '';
    return latin1.encode(rest);
  }

  void _schedule(String rid, String authority, String encoded) {
    unawaited(() async {
      try {
        final raw = base64.decode(encoded);
        final response = await _perform(authority, raw).timeout(
          const Duration(seconds: 25),
          onTimeout: () => throw TimeoutException('bridge exchange timeout'),
        );
        await _writeResponse(rid, response);
      } on Object catch (error) {
        await _writeResponse(rid, utf8.encode('!$error'));
      }
    }());
  }

  /// Performs the bridged request and returns raw HTTP/1.1 response bytes.
  Future<List<int>> _perform(String authority, List<int> raw) async {
    final separator = _headerBodySeparator(raw);
    final headerText = latin1.decode(raw.sublist(0, separator));
    final body = raw.sublist(separator + 4);
    final lines = headerText.split('\r\n');
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 2) {
      throw FormatException('malformed bridged request line: ${lines.first}');
    }
    final method = requestLine[0];
    final target = requestLine[1];
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).trim().toLowerCase()] = line
            .substring(colon + 1)
            .trim();
      }
    }

    // The python side prefixes the authority with its scheme
    // (`https://host:port`), so TLS endpoints stay TLS on the host side.
    final uri = target.startsWith('/')
        ? Uri.parse(
            authority.contains('://') ? '$authority$target'
                : 'http://$authority$target',
          )
        : Uri.parse(target);
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        // Host/Content-Length are re-derived by the host client; framing
        // must not leak through.
        for (final entry in headers.entries)
          if (entry.key != 'host' && entry.key != 'content-length')
            entry.key: entry.value,
      });
    if (body.isNotEmpty) request.bodyBytes = body;

    final response = await _httpClient.send(request);
    final builder = BytesBuilder(copy: false);
    await response.stream.forEach(builder.add);
    var bytes = builder.toBytes();
    final responseHeaders = Map<String, String>.from(response.headers);
    // If the host client transparently decompressed (python never does),
    // drop the encoding marker so http.client reads plain bytes.
    if (responseHeaders['content-encoding']?.contains('gzip') ?? false) {
      if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        bytes = Uint8List.fromList(gzip.decode(bytes));
        responseHeaders.remove('content-encoding');
      }
    }
    responseHeaders
      ..remove('transfer-encoding')
      ..['content-length'] = '${bytes.length}';

    final out = StringBuffer('HTTP/1.1 ${response.statusCode} ')
      ..write('${response.reasonPhrase ?? ""}\r\n');
    responseHeaders.forEach((name, value) => out.write('$name: $value\r\n'));
    out.write('\r\n');
    return [...latin1.encode(out.toString()), ...bytes];
  }

  Future<void> _writeResponse(String rid, List<int> bytes) async {
    final dir = Directory('$_root/dev/.fahttp');
    await dir.create(recursive: true);
    // Write-then-rename so the polling python side never reads a torn file.
    final tmp = File('${dir.path}/$rid.tmp');
    await tmp.writeAsBytes(bytes);
    await tmp.rename('${dir.path}/$rid');
  }
}

int _headerBodySeparator(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 3] == 10) {
      final at = i + 2;
      if (bytes[at] == 13) return i;
    }
  }
  // Tolerate bare-LF header framing.
  final lf = latin1.decode(bytes).indexOf('\n\n');
  if (lf != -1) return lf;
  throw FormatException('bridged request has no header/body separator');
}

/// The python side, materialized into site-packages as `fa_http.py`.
const String kFaHttpPy = r'''
"""Fa sandbox python HTTP bridge (host-routed sockets).

The WASI python build has no socket support and no `ssl` module, so
`urllib`/`http.client`/`requests` cannot open network connections. This
module (auto-installed through `sitecustomize`) routes every request
through the sandbox shell's host HTTP client:

1. The patched `connect()` swaps the real socket for a bridge socket.
2. When `http.client` asks for the response, the buffered request bytes are
   printed to stdout as a control line `\x01FAHTTP1 <id> <authority> <b64>`.
3. The host shell strips control lines from captured stdout, performs the
   request and writes raw response bytes to `/dev/.fahttp/<id>`.
4. The bridge socket feeds those bytes to `http.client.HTTPResponse`, so
   urllib, urllib3 and requests parse the response with standard machinery.
"""

import base64
import io as _io
import os
import sys
import time
import uuid as _uuid

import http.client as _http_client

_MARKER = "\x01FAHTTP1 "
_RESP_DIR = "/dev/.fahttp"
_POLL = 0.03


def _timeout():
    try:
        return float(os.environ.get("FA_HTTP_TIMEOUT", "20"))
    except ValueError:
        return 20.0


def _exchange(authority, raw):
    rid = _uuid.uuid4().hex[:12]
    resp_path = "%s/%s" % (_RESP_DIR, rid)
    encoded = base64.b64encode(raw).decode("ascii")
    sys.stdout.write("%s%s %s %s\n" % (_MARKER, rid, authority, encoded))
    sys.stdout.flush()
    deadline = time.monotonic() + _timeout()
    while True:
        try:
            with open(resp_path, "rb") as handle:
                data = handle.read()
            os.unlink(resp_path)
        except FileNotFoundError:
            if time.monotonic() >= deadline:
                raise TimeoutError("fa_http: host bridge did not respond")
            time.sleep(_POLL)
            continue
        if data[:1] == b"!":
            raise OSError(data[1:].decode("utf-8", "replace"))
        return data


class _BridgeSocket(object):
    """Socket stand-in: buffers the request, replays the bridged response."""

    def __init__(self, authority):
        self._authority = authority
        self._request = bytearray()
        self._response = None

    def sendall(self, data):
        if self._response is not None:
            # Keep-alive reuse: start a fresh exchange.
            self._response = None
            self._request = bytearray()
        self._request += data

    def makefile(self, mode, *args, **kwargs):
        if self._response is None:
            self._response = _exchange(self._authority, bytes(self._request))
        return _io.BytesIO(self._response)

    def settimeout(self, value):
        pass

    def setsockopt(self, *args):
        pass

    def getsockname(self):
        return ("0.0.0.0", 0)

    def getpeername(self):
        return ("0.0.0.0", 0)

    def fileno(self):
        raise OSError("fa_http bridge socket has no file descriptor")

    def close(self):
        pass


def _authority(host, port, scheme):
    default = 443 if scheme == "https" else 80
    host_part = host if port == default else "%s:%d" % (host, port)
    return "%s://%s" % (scheme, host_part)


def _install_stdlib(scheme):
    base = _http_client.HTTPConnection
    default_port = 443 if scheme == "https" else 80

    class _Bridged(base):
        def __init__(self, *args, **kwargs):
            kwargs.pop("context", None)
            base.__init__(self, *args, **kwargs)

        def connect(self):
            self.sock = _BridgeSocket(
                _authority(self.host, self.port, scheme)
            )

    _Bridged.__name__ = (
        "HTTPConnection" if scheme == "http" else "HTTPSConnection"
    )
    return _Bridged


def _patch_urllib3():
    try:
        import urllib3.connection as _c
    except Exception:
        return
    for scheme in ("http", "https"):
        name = "HTTPConnection" if scheme == "http" else "HTTPSConnection"
        cls = getattr(_c, name, None)
        if cls is None:
            continue

        def _new_conn(self, _scheme=scheme):
            return _BridgeSocket(
                _authority(self.host, self.port, _scheme)
            )

        def _connect(self, _scheme=scheme):
            self.sock = _new_conn(self, _scheme)

        try:
            cls._new_conn = _new_conn
            cls.connect = _connect
        except Exception:
            pass


def _install_urllib():
    import urllib.request as _urllib

    class _BridgedHTTPSHandler(_urllib.AbstractHTTPHandler):
        def https_open(self, req):
            return self.do_open(
                _http_client.HTTPSConnection,
                req,
                context=getattr(req, "context", None),
            )

        https_request = _urllib.AbstractHTTPHandler.do_request_

    _urllib.HTTPSHandler = _BridgedHTTPSHandler


def install():
    _http_client.HTTPConnection = _install_stdlib("http")
    _http_client.HTTPSConnection = _install_stdlib("https")
    _install_urllib()
    _patch_urllib3()
''';

/// Materialized into site-packages as `sitecustomize.py`: CPython's `site`
/// module imports it at startup, so every interpreter launch gets the bridge.
const String kFaSitecustomizePy = r'''
"""Fa sandbox: install the host HTTP bridge (see fa_http.py)."""
try:
    import fa_http
    fa_http.install()
except Exception:
    # Never break interpreter startup; python just stays socket-less.
    pass
''';
