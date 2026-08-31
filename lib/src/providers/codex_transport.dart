/// Pure-Dart transport helpers for the Codex HTTP SSE transport.
library;

/// Originator value Codex CLI clients send with ChatGPT backend requests.
const codexOriginator = 'codex_cli_rs';

const _allowedChatgptHosts = {
  'chatgpt.com',
  'chat.openai.com',
  'chatgpt-staging.com',
};
const _allowedChatgptHostSuffixes = ['.chatgpt.com', '.chatgpt-staging.com'];

/// Whether requests to [host] may carry ChatGPT backend credentials.
///
/// Mirrors codex-rs `chatgpt_hosts.rs`: exact apex hosts plus subdomains of
/// `chatgpt.com` / `chatgpt-staging.com` only. Subdomains of
/// `chat.openai.com` are not allowed, and suffix tricks such as
/// `evilchatgpt.com` or `chatgpt.com.evil.example` are rejected.
bool isAllowedChatgptHost(String host) {
  final normalized = host.toLowerCase();
  return _allowedChatgptHosts.contains(normalized) ||
      _allowedChatgptHostSuffixes.any(normalized.endsWith);
}

const _cloudflareCookieNames = {
  '__cf_bm',
  '__cflb',
  '__cfruid',
  '__cfseq',
  '__cfwaitingroom',
  '_cfuvid',
  'cf_clearance',
  'cf_ob_info',
  'cf_use_ob',
};

/// Whether a cookie [name] may be stored for ChatGPT backend traffic.
///
/// Mirrors codex-rs `chatgpt_cloudflare_cookies.rs`: an allowlist of
/// Cloudflare cookies plus any `cf_chl_` challenge cookie.
bool isAllowedCloudflareCookieName(String name) =>
    _cloudflareCookieNames.contains(name) || name.startsWith('cf_chl_');

/// Headers Codex clients attach to ChatGPT backend requests.
Map<String, String> codexRequestHeaders({
  required String accessToken,
  String? accountId,
  required String sessionId,
  required String threadId,
  String originator = codexOriginator,
  String? subagent,
}) => {
  'authorization': 'Bearer $accessToken',
  'ChatGPT-Account-ID': ?accountId,
  'session-id': sessionId,
  'thread-id': threadId,
  'x-client-request-id': threadId,
  'originator': originator,
  'x-openai-subagent': ?subagent,
};

/// In-memory jar holding only allowlisted Cloudflare cookies, keyed by host.
final class CodexCookieJar {
  final Map<String, Map<String, _StoredCookie>> _byHost = {};

  // ponytail: Domain attr ignored, entries host-keyed by the storing URI;
  // bucket by registrable domain instead if subdomain sharing ever matters.
  void store(Uri requestUri, Map<String, String> responseHeaders) {
    if (requestUri.scheme != 'https' ||
        !isAllowedChatgptHost(requestUri.host)) {
      return;
    }
    final bucket = _byHost.putIfAbsent(requestUri.host, () => {});
    for (final header in responseHeaders.entries) {
      if (header.key.toLowerCase() != 'set-cookie') continue;
      for (final raw in _splitJoinedCookies(header.value)) {
        _storeCookie(bucket, raw);
      }
    }
  }

  /// Cookie header for [uri], or null when no stored cookie applies.
  String? cookieHeader(Uri uri) {
    if (uri.scheme != 'https' || !isAllowedChatgptHost(uri.host)) return null;
    final bucket = _byHost[uri.host];
    if (bucket == null) return null;
    final pairs = [
      for (final cookie in bucket.values)
        if (_appliesTo(cookie, uri)) '${cookie.name}=${cookie.value}',
    ];
    return pairs.isEmpty ? null : pairs.join('; ');
  }

  void _storeCookie(Map<String, _StoredCookie> bucket, String raw) {
    final separator = raw.indexOf('=');
    if (separator <= 0) return;
    final name = raw.substring(0, separator).trim();
    if (!isAllowedCloudflareCookieName(name)) return;
    final attributes = raw.substring(separator + 1).split(';');
    final value = attributes.first.trim();
    var path = '/';
    int? maxAge;
    for (final attribute in attributes.skip(1)) {
      final eq = attribute.indexOf('=');
      if (eq == -1) continue;
      final key = attribute.substring(0, eq).trim().toLowerCase();
      final attributeValue = attribute.substring(eq + 1).trim();
      if (key == 'path' && attributeValue.isNotEmpty) {
        path = attributeValue;
      } else if (key == 'max-age') {
        maxAge = int.tryParse(attributeValue);
      }
    }
    if (value.isEmpty || (maxAge != null && maxAge <= 0)) {
      bucket.remove(name);
      return;
    }
    bucket[name] = _StoredCookie(name: name, value: value, path: path);
  }
}

class _StoredCookie {
  const _StoredCookie({
    required this.name,
    required this.value,
    required this.path,
  });

  final String name;
  final String value;
  final String path;
}

bool _appliesTo(_StoredCookie cookie, Uri uri) {
  final path = uri.path.isEmpty ? '/' : uri.path;
  if (!path.startsWith(cookie.path)) return false;
  if (cookie.path.endsWith('/')) return true;
  return path.length == cookie.path.length ||
      path.codeUnitAt(cookie.path.length) == 0x2f;
}

final RegExp _cookieStart = RegExp(r'^\s*[^;,\s]+=');

/// Splits a `set-cookie` header value that may join multiple cookies with
/// commas. A comma splits only when the next token looks like `name=`, so
/// `Expires=Fri, 28 Aug 2026 …` stays intact.
List<String> _splitJoinedCookies(String header) {
  final cookies = <String>[];
  var start = 0;
  for (
    var comma = header.indexOf(',');
    comma != -1;
    comma = header.indexOf(',', comma + 1)
  ) {
    if (_cookieStart.hasMatch(header.substring(comma + 1))) {
      cookies.add(header.substring(start, comma));
      start = comma + 1;
    }
  }
  cookies.add(header.substring(start));
  return cookies;
}

/// One Codex usage window, as advertised by the ChatGPT backend.
final class CodexRateLimitWindow {
  const CodexRateLimitWindow({
    required this.usedPercent,
    this.windowMinutes,
    this.resetsAt,
  });

  final double usedPercent;

  /// Window length in minutes, when advertised.
  final int? windowMinutes;

  /// Unix epoch seconds at which the window resets, when advertised.
  final int? resetsAt;
}

/// Codex usage limits from a ChatGPT backend response.
final class CodexRateLimits {
  const CodexRateLimits({this.primary, this.secondary, this.limitName});

  final CodexRateLimitWindow? primary;
  final CodexRateLimitWindow? secondary;
  final String? limitName;
}

/// Parses the `x-codex-*` rate limit headers of a ChatGPT backend response.
///
/// Header lookup is case-insensitive. Garbage numbers are treated as absent.
/// A window exists only when its used-percent header parses and at least one
/// field is non-zero; returns null when nothing usable was advertised.
CodexRateLimits? parseCodexRateLimits(Map<String, String> headers) {
  String? headerValue(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value.trim();
    }
    return null;
  }

  CodexRateLimitWindow? window(String prefix) {
    final usedPercent = double.tryParse(
      headerValue('$prefix-used-percent') ?? '',
    );
    if (usedPercent == null) return null;
    final windowMinutes = int.tryParse(
      headerValue('$prefix-window-minutes') ?? '',
    );
    final resetsAt = int.tryParse(headerValue('$prefix-reset-at') ?? '');
    if (usedPercent == 0 && (windowMinutes ?? 0) == 0 && resetsAt == null) {
      return null;
    }
    return CodexRateLimitWindow(
      usedPercent: usedPercent,
      windowMinutes: windowMinutes,
      resetsAt: resetsAt,
    );
  }

  final primary = window('x-codex-primary');
  final secondary = window('x-codex-secondary');
  final limitName = headerValue('x-codex-limit-name');
  if (primary == null && secondary == null && limitName == null) return null;
  return CodexRateLimits(
    primary: primary,
    secondary: secondary,
    limitName: limitName,
  );
}
