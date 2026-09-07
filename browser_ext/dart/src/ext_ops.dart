// Pure dispatch for the `ext_request` op surface (panel → SW). The panel
// is an extension page and may use host capabilities a web page cannot:
// the user's LIVE cookie jar (CodeMie's cookie auth without any SSO
// dance), SW-relayed HTTP (MV3 service workers + `<all_urls>` host
// permissions bypass CORS, so provider endpoints that never send CORS
// headers are reachable), and tab creation (open the provider's login
// page for an interactive sign-in).
//
// The backend is injectable so the VM suite pins the dispatch (params
// validation, response shapes, bounded waits) while the SW wires it to
// chrome.* + fetch.
import 'dart:async';

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
}

final class ExtHttpResponse {
  const ExtHttpResponse({required this.status, required this.body});

  final int status;
  final String body;
}

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
    default:
      throw 'unknown ext op: $op';
  }
}
