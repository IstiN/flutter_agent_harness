// Pure dispatch for the `ext_request` op surface (panel → SW). The panel
// is an extension page and may use host capabilities a web page cannot:
// the user's LIVE cookie jar (CodeMie's cookie auth without any SSO
// dance), SW-relayed HTTP (MV3 service workers + `<all_urls>` host
// permissions bypass CORS, so provider endpoints that never send CORS
// headers are reachable), tab creation (open the provider's login page
// for an interactive sign-in), and chat-attachment staging into the
// embedded agent's sandbox (issue #313 — the sandbox is SW-local; the
// "relay" hop is one message).
//
// The backend is injectable so the VM suite pins the dispatch (params
// validation, response shapes, bounded waits) while the SW wires it to
// chrome.* + fetch.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// One cookie of the user's live jar (scoped read — see [handleExtOp]).
final class ExtCookie {
  const ExtCookie({required this.name, required this.value, this.domain});

  final String name;
  final String value;
  final String? domain;
}

/// The host capabilities the ops dispatch drives. The SW binds these to
/// `chrome.cookies`, `fetch` and `chrome.tabs`; tests use fakes.
abstract interface class ExtOpsBackend {
  Future<List<ExtCookie>> cookiesGetAll({String? url, String? domain});

  /// One HTTP round-trip from the SW (no CORS there): returns the body
  /// text plus the status code.
  Future<ExtHttpResponse> fetchString(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  });

  Future<void> tabsCreate(String url);

  /// Stages one chat attachment into the agent env's uploads/ with the
  /// app's EXACT semantics (the shared core `stageUpload` helper —
  /// sanitize, dedupe, directory); returns the env-relative path the
  /// outgoing message references.
  Future<String> stageUpload(String name, Uint8List bytes);

  /// Best-effort delete of a staged upload path (a pending chip removed
  /// before send). Only uploads/ paths qualify; failures are ignored.
  Future<void> discardUpload(String path);

  /// The [paths] NOT present in the agent env right now — a chip staged
  /// before an SW restart can point at a file that no longer exists.
  Future<List<String>> missingUploads(List<String> paths);
}

final class ExtHttpResponse {
  const ExtHttpResponse({required this.status, required this.body});

  final int status;
  final String body;
}

/// Hard cap for one staged upload: 20 MB (issue #313). The SW's memory FS
/// holds everything in RAM and mirrors it into chrome.storage, so the
/// staging surface refuses oversized payloads BEFORE writing — the app's
/// IndexedDB quota story does not apply here. Text pastes and normal
/// attachments fit with an order of magnitude to spare.
const int kMaxStageUploadBytes = 20 * 1024 * 1024;

String _tooLarge(int bytes) =>
    'upload too large: $bytes bytes exceeds the '
    '${kMaxStageUploadBytes ~/ (1024 * 1024)} MB staging cap';

/// Ops bound per request. Unknown ops are a structured error, never a
/// crash; every fetch URL must be http(s) — the panel is trusted (an
/// extension page) but `file:`/`chrome:` targets are still refused.
Future<Map<String, dynamic>> handleExtOp(
  ExtOpsBackend backend,
  String op,
  Map<String, dynamic> params,
) async {
  switch (op) {
    case 'cookies.get_all':
      final url = params['url'] as String?;
      final domain = params['domain'] as String?;
      if ((url == null || url.isEmpty) && (domain == null || domain.isEmpty)) {
        throw 'cookies.get_all needs a "url" or "domain" param';
      }
      return backend
          .cookiesGetAll(url: url, domain: domain)
          .then(
            (cookies) => {
              'cookies': [
                for (final c in cookies)
                  {'name': c.name, 'value': c.value, 'domain': c.domain},
              ],
            },
          )
          .timeout(const Duration(seconds: 15));
    case 'fetch':
      final url = params['url'] as String?;
      if (url == null ||
          !(url.startsWith('https://') || url.startsWith('http://'))) {
        throw 'fetch needs an http(s) "url"';
      }
      final method = (params['method'] as String?) ?? 'GET';
      final headers =
          (params['headers'] as Map?)?.cast<String, String>() ?? const {};
      final body = params['body'] as String?;
      return backend
          .fetchString(url, method: method, headers: headers, body: body)
          .then((r) => {'status': r.status, 'body': r.body})
          .timeout(const Duration(seconds: 30));
    case 'tabs.create':
      final url = params['url'] as String?;
      if (url == null || url.isEmpty) {
        throw 'tabs.create needs a "url"';
      }
      return backend
          .tabsCreate(url)
          .then((_) => {'opened': true})
          .timeout(const Duration(seconds: 15));
    case 'agent.stageUpload':
      final name = params['name'] as String?;
      final encoded = params['bytes'] as String?;
      if (name == null || name.isEmpty) {
        throw 'agent.stageUpload needs a "name"';
      }
      if (encoded == null) {
        throw 'agent.stageUpload needs base64 "bytes"';
      }
      // Size guard BEFORE the decode allocates (base64 inflates by 4/3).
      if (encoded.length * 3 ~/ 4 > kMaxStageUploadBytes) {
        throw _tooLarge(encoded.length * 3 ~/ 4);
      }
      final Uint8List bytes;
      try {
        bytes = base64Decode(encoded);
      } on FormatException {
        throw 'agent.stageUpload needs base64 "bytes"';
      }
      if (bytes.length > kMaxStageUploadBytes) {
        throw _tooLarge(bytes.length);
      }
      return {'path': await backend.stageUpload(name, bytes)};
    case 'agent.discardUpload':
      final path = params['path'] as String?;
      if (path == null || path.isEmpty) {
        throw 'agent.discardUpload needs a "path"';
      }
      await backend.discardUpload(path);
      return const {'discarded': true};
    case 'agent.missingUploads':
      final paths = (params['paths'] as List?)?.cast<String>() ?? const [];
      return {'missing': await backend.missingUploads(paths)};
    default:
      throw 'unknown ext op: $op';
  }
}
