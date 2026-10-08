/// Shared internals for provider adapters: request-header merging, HTTP
/// error carriers, error formatting, the mutable stream state, the HTTP
/// send/abort race, SSE wiring, block-end dispatch, and the terminal error
/// event — everything that is identical across the pi provider ports.
///
/// Internal to the package: not exported from `flutter_agent_harness.dart`.
/// Extracted so the provider ports stay mechanically close to their pi
/// originals without duplicating code (the pre-commit duplication gate is
/// < 1%).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../json_parse.dart';
import '../model.dart';
import '../rate_limit_info.dart';
import '../sse_decoder.dart';
import '../types.dart';
import 'conn_trace.dart' show connTraceWrapProviderClient;
import 'stall_sentinel.dart'
    show providerConnectStallFired, providerIdleStallFired;
import 'conn_trace_bench.dart';
import 'transient_retry_stream.dart';

/// Placeholder substituted for user-message images when the target model has
/// no `image` input (pi's `NON_VISION_USER_IMAGE_PLACEHOLDER`).
const nonVisionUserImagePlaceholder =
    '(image omitted: model does not support images)';

/// Placeholder substituted for tool-result images when the target model has
/// no `image` input (pi's `NON_VISION_TOOL_IMAGE_PLACEHOLDER`).
const nonVisionToolImagePlaceholder =
    '(tool image omitted: model does not support images)';

/// Placeholder substituted for user-message images after the backend
/// rejected the request as undecodable (e.g. Gemini's 400 `Unable to
/// process input image`): the retry tells the model WHY the image is gone
/// instead of silently dropping it.
const undecodableUserImagePlaceholder =
    '(image omitted: the model backend could not decode it — the file may '
    'be corrupt or in an unsupported format)';

/// Tool-result counterpart of [undecodableUserImagePlaceholder].
const undecodableToolImagePlaceholder =
    '(tool image omitted: the model backend could not decode it — the file '
    'may be corrupt or in an unsupported format)';

/// Host-set hook for the text-only strip ([downgradeUnsupportedImages]):
/// reports how many image blocks the model's declared modalities dropped,
/// so the run shows a VISIBLE notice instead of silence (issue #638).
/// Null (the default) keeps the strip silent.
typedef TextOnlyImageDropNotice = void Function(int droppedCount);

/// The active text-only drop reporter - wired once by the host at boot.
TextOnlyImageDropNotice? textOnlyImageDropNotice;

/// pi's `replaceImagesWithPlaceholder`: consecutive images collapse into a
/// single placeholder, and a text block already equal to the placeholder
/// suppresses a duplicate. [onImage] fires once per replaced image block.
List<ContentBlock> _replaceImagesWithPlaceholder(
  List<ContentBlock> content,
  String placeholder, {
  void Function()? onImage,
}) {
  final result = <ContentBlock>[];
  var previousWasPlaceholder = false;
  for (final block in content) {
    if (block is ImageContent) {
      if (!previousWasPlaceholder) {
        result.add(TextContent(text: placeholder));
        onImage?.call();
      }
      previousWasPlaceholder = true;
      continue;
    }
    result.add(block);
    previousWasPlaceholder = block is TextContent && block.text == placeholder;
  }
  return result;
}

/// Replaces image blocks with explicit placeholder text when [model] has no
/// `image` input, so nothing is dropped silently at request time.
///
/// Ported from the `downgradeUnsupportedImages` half of pi's
/// `transformMessages` pre-pass (transform-messages.ts): user messages and
/// tool results get distinct placeholders; the image bytes stay in the
/// session transcript, only the request payload is rewritten. Each adapter
/// runs this at the top of its message conversion.
List<Message> downgradeUnsupportedImages(List<Message> messages, Model model) {
  if (model.input.contains('image')) {
    return messages;
  }
  var dropped = 0;
  final out = _replaceImages(
    messages,
    nonVisionUserImagePlaceholder,
    nonVisionToolImagePlaceholder,
    onImage: () => dropped++,
  );
  if (dropped > 0) textOnlyImageDropNotice?.call(dropped);
  return out;
}

/// Replaces EVERY image block with [undecodableUserImagePlaceholder] /
/// [undecodableToolImagePlaceholder], regardless of the model's declared
/// modalities. Used when a vision-capable backend rejected the request as
/// undecodable (Gemini's 400 `Unable to process input image`): the adapter
/// retries once with the images downgraded, so the turn survives and the
/// model can tell the user the image was unreadable.
List<Message> downgradeUndecodableImages(List<Message> messages) {
  return _replaceImages(
    messages,
    undecodableUserImagePlaceholder,
    undecodableToolImagePlaceholder,
  );
}

/// Replaces EVERY image block with the non-vision placeholders, regardless
/// of the model's declared modalities. Used when a text-only backend
/// rejected the request's image parts (issue #42: z.ai glm-5.3 400
/// `messages.content.type is invalid, allowed values: ['text']`): the
/// adapter retries once with the images downgraded, so the turn survives
/// and the model can explain the swap instead of dying with a raw API
/// error.
List<Message> downgradeAllImages(List<Message> messages) {
  return _replaceImages(
    messages,
    nonVisionUserImagePlaceholder,
    nonVisionToolImagePlaceholder,
  );
}

/// Whether [messages] contains any [ImageContent] (user messages and tool
/// results) — guards the undecodable-image retry so image-shaped backend
/// errors on image-free requests don't trigger a pointless second call.
bool messagesContainImages(List<Message> messages) {
  for (final message in messages) {
    if (message is UserMessage && message.content is List<ContentBlock>) {
      if ((message.content as List<ContentBlock>).any(
        (b) => b is ImageContent,
      )) {
        return true;
      }
    }
    if (message is ToolResultMessage) {
      if (message.content.any((b) => b is ImageContent)) return true;
    }
  }
  return false;
}

/// Shared machinery of [downgradeUnsupportedImages] and
/// [downgradeUndecodableImages]: swap image blocks for the given per-kind
/// placeholder text, keeping every other field of the message intact.
List<Message> _replaceImages(
  List<Message> messages,
  String userPlaceholder,
  String toolPlaceholder, {
  void Function()? onImage,
}) {
  return [
    for (final message in messages)
      if (message is UserMessage && message.content is List<ContentBlock>)
        UserMessage(
          content: _replaceImagesWithPlaceholder(
            message.content as List<ContentBlock>,
            userPlaceholder,
            onImage: onImage,
          ),
          timestamp: message.timestamp,
        )
      else if (message is ToolResultMessage)
        ToolResultMessage(
          toolCallId: message.toolCallId,
          toolName: message.toolName,
          content: _replaceImagesWithPlaceholder(
            message.content,
            toolPlaceholder,
            onImage: onImage,
          ),
          isError: message.isError,
          timestamp: message.timestamp,
        )
      else
        message,
  ];
}

/// Whether [headers] contains a non-empty value for [name]
/// (case-insensitive).
///
/// Ported from pi's `hasHeader`.
bool hasHeader(Map<String, String?>? headers, String name) {
  if (headers == null) {
    return false;
  }
  final expected = name.toLowerCase();
  for (final entry in headers.entries) {
    final value = entry.value;
    if (entry.key.toLowerCase() == expected &&
        value != null &&
        value.trim().isNotEmpty) {
      return true;
    }
  }
  return false;
}

/// Merges request headers: [defaults] first, then [modelHeaders], then
/// [optionsHeaders]. An option header with a `null` value suppresses the
/// header with the same name (pi's `ProviderHeaders` semantics).
Map<String, String> mergeProviderHeaders(
  Map<String, String> defaults,
  Map<String, String>? modelHeaders,
  Map<String, String?>? optionsHeaders,
) {
  final headers = <String, String>{...defaults, ...?modelHeaders};
  if (optionsHeaders != null) {
    for (final entry in optionsHeaders.entries) {
      final value = entry.value;
      if (value == null) {
        headers.remove(entry.key);
      } else {
        headers[entry.key] = value;
      }
    }
  }
  return headers;
}

/// Runs an adapter's `onPayload` hook, returning the replacement payload or
/// [params] unchanged when the hook is absent or returns `null`.
Future<Map<String, dynamic>> applyPayloadHook(
  Map<String, dynamic> params,
  Model model,
  FutureOr<Map<String, dynamic>?> Function(Map<String, dynamic>, Model)?
  onPayload,
) async {
  final nextParams = await onPayload?.call(params, model);
  return nextParams ?? params;
}

/// Thrown internally when a `CancelToken` fires; caught and converted into an
/// aborted `ErrorEvent`. Never escapes an adapter.
final class AbortedError implements Exception {
  /// Creates an abort marker error.
  const AbortedError();
}

/// A non-200 HTTP response, carrying the status and raw body for error
/// reporting (the Dart counterpart of the SDK error objects pi normalizes).
final class ProviderHttpError implements Exception {
  /// Creates an HTTP error with [statusCode] and raw response [body].
  ///
  /// [retryAfter] is the provider-suggested wait parsed from the
  /// `Retry-After` response header, when present and parseable.
  ///
  /// [requestUrl] and [redirectLocation] are supplied by
  /// [sendProviderRequest] so that [formatProviderError] can diagnose
  /// expired SSO sessions / wrong endpoints from the response context.
  const ProviderHttpError(
    this.statusCode,
    this.body, {
    this.retryAfter,
    this.rateLimit,
    this.requestUrl,
    this.redirectLocation,
    this.answeredHtml = false,
    this.answeredJson = false,
  });

  /// The HTTP status code.
  final int statusCode;

  /// The raw response body.
  final String body;

  /// The provider-suggested delay before retrying (parsed from the
  /// `Retry-After` response header), typically set on HTTP 429 responses.
  final Duration? retryAfter;

  /// The structured 429 decode (issue #867), when the failure was a
  /// rate limit. [formatProviderError] renders it human; the raw payload
  /// stays inside for diagnostics.
  final RateLimitInfo? rateLimit;

  /// Request URL that produced the error, when known.
  final Uri? requestUrl;

  /// `Location` response header on a redirect response, when present.
  final String? redirectLocation;

  /// True when the endpoint answered `200 OK` with an HTML page instead of
  /// the event stream — the signature of an SSO-gated API whose session
  /// died: the transparent redirect (browser jar / fetch follows 3xx)
  /// lands on the login portal, and without this flag the adapter would
  /// finish with an EMPTY assistant message and no hint why.
  final bool answeredHtml;

  /// True when the endpoint answered `200 OK` with a buffered JSON body
  /// instead of the event stream — a gateway/front-proxy error object
  /// (`{"error": …}`) that never went through SSE framing. The body is
  /// short and diagnostic, so [formatProviderError] surfaces it (unlike
  /// the HTML login page, which is transcript junk).
  final bool answeredJson;
}

/// Composes the display string for an `ErrorEvent.errorMessage`.
///
/// Simplified port of pi's `formatProviderError(normalizeProviderError(e))`:
/// there is no SDK whose error shapes need probing here.
String formatProviderError(Object error) {
  if (error is ProviderHttpError) {
    if (error.answeredHtml) return _formatHtmlAnswer(error);
    if (error.answeredJson) return _formatJsonAnswer(error);
    final redirect = _formatAuthRedirect(error);
    if (redirect != null) return redirect;

    // Issue #867: a structured 429 renders the human message — plan,
    // server-derived reset, next step. The raw payload stays on
    // [RateLimitInfo.rawBody] and never reaches the transcript.
    if (error.rateLimit case final rateLimit?) {
      return '${error.statusCode}: ${formatRateLimitMessage(rateLimit)}';
    }

    final body = error.body.trim();
    if (body.isEmpty) {
      return 'Request failed with status ${error.statusCode}';
    }
    return '${error.statusCode}: $body';
  }
  if (error is http.ClientException) {
    return error.message;
  }
  // Issue #1036 (review round 1): keep the "TimeoutException" word in the
  // rendered text — it IS the contract the model-roles failover chain
  // (`fallback_stream._transportPatterns`) and the providers queue
  // (`providers_queue_runtime._timeoutPatterns`) classify on, routing every
  // watchdog timeout to the retry/failover path. Render the diagnostic
  // message after the keyword, not the exception wrapper's clock noise.
  if (error is TimeoutException) {
    return 'TimeoutException: ${error.message ?? 'provider request timed out'}';
  }
  if (error is StateError) {
    return error.message;
  }
  if (error is FormatException) {
    return error.message;
  }
  return error.toString();
}

/// Marker used by UIs to detect an "auth session expired" provider error
/// and offer a re-authorize button. The format is `[[auth-expired:<id>]]`
/// and it is appended at the end of the formatted message.
const authExpiredMarkerPrefix = '[[auth-expired:';

/// Whether [url] matches a known provider whose SSO cookie can expire and
/// produce a redirect.
bool _isKnownAuthExpiredHost(String url) {
  final lower = url.toLowerCase();
  return lower.contains('codemie') || lower.contains('code-assistant-api');
}

/// Returns the provider id for an auth-expired formatted message, or null
/// if there is no marker.
///
/// UIs can call this to render a re-authorize card instead of the raw
/// redirect page. See [formatProviderError] and [authExpiredMarkerPrefix].
String? authExpiredProvider(String formattedError) {
  final start = formattedError.indexOf(authExpiredMarkerPrefix);
  if (start < 0) return null;
  final close = formattedError.indexOf(
    ']]',
    start + authExpiredMarkerPrefix.length,
  );
  if (close < 0) return null;
  return formattedError.substring(
    start + authExpiredMarkerPrefix.length,
    close,
  );
}

/// Removes the auth-expired marker (and surrounding whitespace) from the
/// formatted error, leaving the human-readable part for display.
String stripAuthExpiredMarker(String formattedError) {
  final start = formattedError.indexOf(authExpiredMarkerPrefix);
  if (start < 0) return formattedError;
  final close = formattedError.indexOf(
    ']]',
    start + authExpiredMarkerPrefix.length,
  );
  if (close < 0) return formattedError;
  final end = close + 2;
  // Strip trailing whitespace before the marker too.
  var cut = start;
  while (cut > 0 && formattedError[cut - 1] == ' ') {
    cut--;
  }
  return formattedError.substring(0, cut) + formattedError.substring(end);
}

/// Produces a friendly explanation for a `200 OK` that carried an HTML page
/// ([ProviderHttpError.answeredHtml]). Same diagnosis as the 3xx path — an
/// expired SSO session — but the redirect was followed transparently, so no
/// status/Location ever surfaced. The HTML itself (a login SPA shell) is
/// never useful in the transcript; the marker lets actionable UIs render a
/// re-authorize card.
String _formatHtmlAnswer(ProviderHttpError error) {
  final requestUrl = error.requestUrl?.toString() ?? '';
  if (_isKnownAuthExpiredHost(requestUrl)) {
    return 'CodeMie session expired — the endpoint answered the API call '
        'with the SSO login page instead of the event stream (the dead '
        'session cookie was silently redirected). Re-authorize to refresh '
        'the session (CLI: /provider codemie sso). '
        '$authExpiredMarkerPrefix'
        'codemie]]';
  }
  return 'The endpoint answered with an HTML page instead of a data stream '
      '— usually an expired SSO login (the request was silently redirected '
      'to a login portal) or a wrong URL.';
}

/// Produces the message for a `200 OK` that carried a buffered JSON body
/// ([ProviderHttpError.answeredJson]): a gateway answered the streaming
/// request with a plain error object (no SSE framing). Unlike the HTML
/// login page the body is small and diagnostic — surface it (bounded) so
/// the real gateway message (unknown model, dead session, quota) is
/// visible instead of an empty assistant turn.
String _formatJsonAnswer(ProviderHttpError error) {
  final body = error.body.trim();
  final preview = body.length > 500 ? '${body.substring(0, 500)}…' : body;
  return 'The endpoint answered 200 with a JSON body instead of an event '
      'stream — the gateway rejected the request without a proper status '
      'code: $preview';
}

/// Produces a friendly explanation for an HTTP redirect (3xx). These are
/// almost always expired SSO sessions or wrong URLs — the raw HTML redirect
/// page is not useful in the transcript, and we want a human-readable hint
/// plus a machine-readable marker for actionable UIs.
String? _formatAuthRedirect(ProviderHttpError error) {
  if (error.statusCode < 300 || error.statusCode >= 400) return null;

  final location = error.redirectLocation;
  final locationBit = location != null && location.isNotEmpty
      ? ' → $location'
      : '';

  final requestUrl = error.requestUrl?.toString().toLowerCase() ?? '';
  final locationLower = location?.toLowerCase() ?? '';
  final isCodemie =
      _isKnownAuthExpiredHost(requestUrl) ||
      _isKnownAuthExpiredHost(locationLower);

  if (isCodemie) {
    return '${error.statusCode}: CodeMie session expired — the endpoint '
        'redirected the request to the SSO login portal$locationBit. '
        'Re-authorize to refresh the token (CLI: /provider codemie sso). '
        '$authExpiredMarkerPrefix'
        'codemie]]';
  }

  return '${error.statusCode}: the endpoint answered with an HTTP redirect'
      '$locationBit instead of JSON — usually an expired SSO login or a '
      'moved URL.';
}

/// Same-origin redirect hops the shared layer follows itself. Auto-follow
/// is DISABLED on every request (`followRedirects` forced off below): the
/// redirect decision is made HERE so a cross-origin 3xx can never re-send
/// `Authorization: Bearer …` to the redirect target — the shared-layer
/// rule (SEC-01 class), not a per-relay or per-client behavior some
/// HTTP stacks (URLSession-backed clients) get wrong by default. Five
/// hops mirrors the common client default.
const int _maxProviderRedirects = 5;

bool _isRedirectStatus(int statusCode) => statusCode >= 300 && statusCode < 400;

/// The absolute redirect target, or null when [statusCode] is not a
/// redirect or the `Location` header is absent/unparseable.
Uri? _redirectTarget(Uri from, int statusCode, String? location) {
  if (!_isRedirectStatus(statusCode) || location == null || location.isEmpty) {
    return null;
  }
  final parsed = Uri.tryParse(location);
  if (parsed == null) return null;
  return from.resolveUri(parsed);
}

/// Strict same-origin: scheme, host and effective port all equal — the
/// only redirect kind that may keep the request's credentials.
bool _sameOrigin(Uri a, Uri b) {
  int effectivePort(Uri u) =>
      u.port != 0 ? u.port : (u.scheme == 'https' ? 443 : 80);
  return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      effectivePort(a) == effectivePort(b);
}

/// Re-issues [previous] at [target] for a same-origin redirect hop:
/// method, body and headers ride along (credentials stay on-origin) —
/// except `303 See Other`, which RFC 9110 (and dart:io's prior
/// auto-follow on this path) downgrades to a body-less GET.
http.Request _reissue(http.Request previous, Uri target, int statusCode) {
  final switchToGet = statusCode == 303;
  final reissued = http.Request(switchToGet ? 'GET' : previous.method, target)
    ..followRedirects = false
    ..headers.addAll({
      for (final entry in previous.headers.entries)
        if (entry.key.toLowerCase() != 'content-length') entry.key: entry.value,
    });
  if (!switchToGet) reissued.bodyBytes = previous.bodyBytes;
  return reissued;
}

/// Sends [request], racing [cancelToken] (abort wins), and validates the
/// response status.
///
/// Redirects are decided HERE, never by the underlying client
/// (`followRedirects` is forced off): a same-origin hop is re-issued
/// verbatim (method/body/headers — credentials intact), while a
/// cross-origin 3xx FAILS as [ProviderHttpError] carrying the
/// `Location`. An endpoint that bounces an API call to another host
/// (expired SSO portal, moved URL) never gets the request re-sent, so
/// `Authorization: Bearer …` can never leak to a redirect target — the
/// SEC-01 trust boundary lives in this shared layer, not per relay.
///
/// Throws [AbortedError] when the token fires before the headers arrive
/// and [ProviderHttpError] on a non-200 status (with the body consumed
/// for the error message). The adapter's try/catch turns both into error
/// events.
Future<http.StreamedResponse> sendProviderRequest(
  http.Client httpClient,
  http.Request request,
  CancelToken? cancelToken,
) async {
  request.followRedirects = false;
  var current = request;
  for (var redirects = 0; ; redirects++) {
    final response = await sendWatchedProviderRequest(
      httpClient,
      current,
      cancelToken,
    );
    final location = response.headers['location'];
    final target = _redirectTarget(current.url, response.statusCode, location);
    if (target == null) return _validateStreamResponse(current, response);
    if (redirects >= _maxProviderRedirects ||
        !_sameOrigin(current.url, target)) {
      final body = await response.stream.bytesToString();
      throw ProviderHttpError(
        response.statusCode,
        body,
        requestUrl: current.url,
        redirectLocation: location,
      );
    }
    // Consume the (tiny) redirect body so the connection can be reused.
    await response.stream.drain<void>();
    current = _reissue(current, target, response.statusCode);
  }
}

/// One watched send: the cancel-token race plus the connect watchdog, with
/// a bounded TRANSPARENT retry when the watchdog kills a request that never
/// received a byte (issue #1121).
///
/// Public for transports that must own their response semantics and so
/// bypass [sendProviderRequest]'s redirect decision and status/body
/// validation — chatgpt-codex stores Cloudflare cookies from error
/// responses and replays challenges itself, so it takes the raw watched
/// send and keeps its own cookie/challenge logic.
Future<http.StreamedResponse> sendWatchedProviderRequest(
  http.Client httpClient,
  http.Request request,
  CancelToken? cancelToken,
) async {
  for (var attempt = 0; ; attempt++) {
    // A sent `http.Request` is finalized by the client and cannot be sent
    // again — every attempt after the first rides a fresh clone (the
    // redirect `_reissue` clones for the same reason).
    final attemptRequest = attempt == 0
        ? request
        : _reissue(request, request.url, 0);
    try {
      return await _sendWatchedOnce(
        httpClient,
        attemptRequest,
        cancelToken,
        attempt,
      );
    } on TimeoutException {
      // The connect watchdog fired (issue #1121). `httpClient.send`
      // completes only when the response HEADERS arrive, so a timeout in
      // THIS layer means zero response bytes — the provider never started
      // generating. That makes an in-place retry safe where a mid-stream
      // retry is not: no partial stream to corrupt, no committed state, and
      // nothing double-billed (a request the endpoint never answered is not
      // a billed generation) — the identical payload is simply re-sent.
      // The budget is deliberately separate from the roles failover ladder
      // (a network stall must not rotate the model chain, #1066 semantics)
      // and from TransientRetryStream (governed by bytes AFTER the first).
      // Mid-stream silence never re-enters here — the idle watchdog fires
      // downstream in createSseIterator — so only the never-started request
      // ever retries.
      if (attempt >= providerConnectRetries) rethrow;
      final delay = providerConnectRetryBackoff * (1 << attempt);
      // Observable on the EXISTING retry surface: the CLI host prints a dim
      // `[net]` line + fa.log entry; hosts leaving the hook null stay
      // silent — no new telemetry.
      transientRetryNotice?.call(
        attempt + 1,
        providerConnectRetries + 1,
        delay,
        'connect stall: no response bytes',
      );
      // Bounded backoff; the sleeper races the cancel token, so a user
      // abort during the wait wins over the pending retry.
      connTrace.retryScheduled(
        attempt: attempt + 1,
        delaySec: delay.inMicroseconds / 1e6,
        reason: 'connect stall: no response bytes',
      );
      final survived = await transientRetrySleeper(delay, cancelToken);
      if (!survived) {
        cancelToken?.throwIfCancelled(); // the abort propagates
        rethrow;
      }
    }
  }
}

/// One connect-watched send attempt: no retry. [attempt] (0-based) only
/// labels the orphan janitor's notice.
Future<http.StreamedResponse> _sendWatchedOnce(
  http.Client httpClient,
  http.Request request,
  CancelToken? cancelToken,
  int attempt,
) async {
  // Re-pin the runtime type parameter BEFORE the watchdog: IOClient.send's
  // future is reified as package:http's internal IOStreamedResponse, and
  // `.timeout` runtime-checks its value-returning onTimeout closure against
  // that reified type — the () => http.StreamedResponse watchdog fails the
  // cast the moment a REAL client is used (CI core shard 1/4, run
  // 36802277315: "type '() => StreamedResponse' is not a subtype of type
  // '(() => FutureOr<IOStreamedResponse>)?' of 'onTimeout'"). A `.then<S>`
  // round-trip reifies the future as Future<http.StreamedResponse> so the
  // closure matches; one microtask hop at header time, no semantic change.
  final responseFuture = httpClient
      .send(request)
      .then<http.StreamedResponse>((response) => response);
  // Issue #1036 (review round 1): name the endpoint in the watchdog error —
  // the rendered "TimeoutException: …" text is the always-retryable contract
  // the failover/queue classifiers match on.
  http.StreamedResponse watchdogTimedOut() {
    // gh-1395 (AC2/AC3, E1): name the connect stall and capture the
    // never-started request's payload — distinct watchdog, distinct trace
    // line, distinct policy entry.
    providerConnectStallFired(request, effectiveProviderConnectTimeout);
    // The attempt is ABANDONED, not aborted: package:http cannot cancel a
    // pending send, and a slow-but-alive endpoint (reasoning model over
    // the first-byte budget) may still answer. Attach a janitor so the
    // late answer is (a) announced on the existing `[net]`/fa.log retry
    // surface instead of dropping silently — the provider may have started
    // generating a body nobody will read — and (b) released: cancelling
    // the body subscription closes the connection at once rather than
    // draining a dead generation into the void (which usually aborts the
    // generation server-side, keeping the nothing-double-billed claim as
    // true as the protocol allows). Late errors land in the janitor's own
    // handler, never the zone (issue #921 discipline). The retry cap
    // bounds the abandoned-attempt multiplication at
    // providerConnectRetries + 1 per stalled turn.
    connTrace.connectWatchdogFired(
      timeoutSec: effectiveProviderConnectTimeout.inMicroseconds / 1e6,
      attempt: attempt,
    );
    unawaited(
      responseFuture.then<Object?>((late) {
        transientRetryNotice?.call(
          0,
          providerConnectRetries + 1,
          Duration.zero,
          'abandoned connect attempt ${attempt + 1} answered late — '
          'response detached, generation dropped',
        );
        return late.stream
            .listen((_) {}, onError: (Object _) {}, cancelOnError: true)
            .cancel();
      }, onError: (Object _) {}),
    );
    throw TimeoutException(
      'provider stream request to ${redactProviderUrl(request.url)} timed out: '
      'no response headers within ${effectiveProviderConnectTimeout.inSeconds}s '
      // The classifier consumes [connectWatchdogTag] (transient_retry_
      // stream.dart): one constant keeps the wording and the retry
      // classification pinned together (issue #1121, review r1).
      '$connectWatchdogTag',
    );
  }

  if (cancelToken == null) {
    return responseFuture.timeout(
      effectiveProviderConnectTimeout,
      onTimeout: watchdogTimedOut,
    );
  }
  return Future.any([
    responseFuture,
    cancelToken.onCancel.then<http.StreamedResponse>(
      (_) => throw const AbortedError(),
    ),
  ]).timeout(effectiveProviderConnectTimeout, onTimeout: watchdogTimedOut);
}

/// The terminal-hop validations: non-200 statuses and the 200 answers
/// that are secretly not event streams (HTML login portal, buffered JSON
/// gateway error).
Future<http.StreamedResponse> _validateStreamResponse(
  http.Request request,
  http.StreamedResponse response,
) async {
  if (response.statusCode != 200) {
    final body = await response.stream.bytesToString();
    throw ProviderHttpError(
      response.statusCode,
      body,
      retryAfter: parseRetryAfter(response.headers['retry-after']),
      // Issue #867: parse once, at the provider — every adapter routing
      // through this send path decodes its 429 (null for other statuses).
      rateLimit: parseRateLimitInfo(
        statusCode: response.statusCode,
        body: body,
        headers: response.headers,
      ),
      requestUrl: request.url,
      redirectLocation: response.headers['location'],
    );
  }

  // A 200 with an HTML body is NEVER a valid event stream: an SSO-gated
  // endpoint (CodeMie et al.) whose session died answers the API call with
  // its login portal after a redirect. Without this guard the SSE consumer
  // sees no `data:` lines and the turn finishes with an empty assistant
  // message — "(empty response — try again)" with zero hint that re-login
  // is needed.
  final contentType = response.headers['content-type'] ?? '';
  final contentTypeLower = contentType.toLowerCase();
  if (contentTypeLower.contains('text/html')) {
    final body = await response.stream.bytesToString();
    throw ProviderHttpError(
      200,
      body,
      requestUrl: request.url,
      answeredHtml: true,
    );
  }

  // A 200 with a buffered JSON body is not an event stream either: a
  // gateway (CodeMie/DIAL et al.) that rejects the request without proper
  // status codes answers `{"error": …}` — a real error object the user
  // must SEE instead of an empty assistant message.
  if (contentTypeLower.contains('application/json')) {
    final body = await response.stream.bytesToString();
    throw ProviderHttpError(
      200,
      body,
      requestUrl: request.url,
      answeredJson: true,
    );
  }
  return response;
}

/// Renders [url] for watchdog/error text: scheme, host, port and path
/// survive; userinfo and query are dropped — a custom provider's baseUrl
/// can carry credentials (`https://user:key@gateway/…`, `?api_key=…`), and
/// the rendered assistant error lands in the transcript verbatim
/// (issue #1036, review round 2).
String redactProviderUrl(Uri url) {
  final port = url.hasPort ? ':${url.port}' : '';
  return '${url.scheme}://${url.host}$port${url.path}';
}

/// Connect/first-headers watchdog for provider calls: an endpoint that
/// never answers the request would otherwise hang the turn forever. Three
/// minutes on purpose: loaded reasoning endpoints (kimi-k3 et al.) may hold
/// a big request for over a minute before the first byte.
const providerConnectTimeout = Duration(seconds: 180);

/// Bounded connect-stall retry budget (issue #1121): how many times a
/// request the connect watchdog killed with ZERO response bytes is re-sent
/// before the failure escalates to the run. 2 retries (3 total attempts):
/// the connect leg alone costs ≈ 3×(180s + 1s+2s backoff) ≈ 9 min against
/// an endpoint that black-holes. This leg sits BELOW TransientRetryStream
/// (3 attempts, 5s apart) and the roles failover ladder, so a hard-down
/// endpoint stacks ≈ 3 connect legs × 3 transient attempts ≈ 27 min per
/// role entry before failover (pre-PR: ≈ 9 min), and the ladder repeats
/// per queue entry — the recovery path of last resort stays the ladder's
/// own budgets, and environments that prefer faster failure shrink
/// `providerTimeouts: connect:` in `~/.fah/config.yaml` (issue #1036),
/// which this retry inherits automatically. This budget is NOT the roles
/// failover ladder's — a connect stall never consumes a failover attempt.
const providerConnectRetries = 2;

/// Base backoff between connect-stall retries; doubles per retry (1s, 2s).
/// Process-wide and injectable in tests, same pattern as
/// [transientRetrySleeper].
Duration providerConnectRetryBackoff = const Duration(seconds: 1);

/// Idle watchdog for provider streams: with no bytes for this long the
/// endpoint is considered wedged — the stream errors (and the roles
/// resolver may fail over) instead of hanging the turn forever. Generous
/// on purpose: reasoning models may think long BETWEEN chunks (kimi-k3
/// thinks for minutes), so this only trips on a truly silent connection.
const providerStreamIdleTimeout = Duration(minutes: 5);

/// Provider watchdog overrides from the `providerTimeouts:` section of
/// `~/.fah/config.yaml` (strict [ConfigException] parsing in
/// `cli_config.dart`) plus the `FA_PROVIDER_TIMEOUT_SECONDS` env override
/// folded in at boot (issue #1036).
final class ProviderTimeoutsOverride {
  /// Creates an override; null fields keep the defaults.
  const ProviderTimeoutsOverride({
    this.connect,
    this.streamIdle,
    this.fetchRead,
  });

  /// Connect/first-headers watchdog override ([providerConnectTimeout]).
  final Duration? connect;

  /// Idle-stream watchdog override ([providerStreamIdleTimeout]).
  final Duration? streamIdle;

  /// Non-streaming fetch watchdog override ([providerFetchReadTimeout]) —
  /// the `FA_PROVIDER_TIMEOUT_SECONDS` env value; the yaml section has no
  /// key for it by design.
  final Duration? fetchRead;
}

/// Process-wide watchdog override, set once at startup from the config file
/// (same pattern as `providerFilterEnvOverride`); tests may set it directly.
/// Null keeps [providerConnectTimeout]/[providerStreamIdleTimeout].
ProviderTimeoutsOverride? providerTimeoutsOverride;

/// Optional HTTP-client factory for platform-specific networking.
///
/// Hosts can inject this to use a native stack (e.g. `CupertinoClient` on
/// iOS/macOS) instead of the default `dart:io` [HttpClient]. The factory is
/// read every time [sharedProviderHttpClient] is called so it can be set
/// once at app startup before any provider request runs.
http.Client Function()? providerHttpClientFactory;

http.Client? _sharedProviderClient;

/// Test/ops seam: drops the cached shared client so the next
/// [sharedProviderHttpClient] call rebuilds it (ConnTrace toggling and
/// factory swaps in tests, issue #1392).
void debugResetSharedProviderHttpClient() => _sharedProviderClient = null;

/// The shared keep-alive HTTP client for provider streams.
///
/// Streaming adapters use it when the caller injects no client: a fresh
/// `http.Client` per request churns a new TCP+TLS connection every turn,
/// which on tool-heavy runs piles up TIME_WAIT sockets until connect()
/// stalls into the watchdog (kimi-cli/pi reuse one client for exactly this
/// reason). The shared client is never closed per call — an aborted stream
/// closes only its own response subscription.
///
/// If [providerHttpClientFactory] is set, its product is used and cached
/// instead of the default [http.Client].
///
/// Issue #1392 (bench round 3): with `FA_CONN_DEBUG=1` (or
/// `FA_PROVIDER_DEBUG`) the inner product is the bench-traced client —
/// every send/first-byte/watchdog event lands as a structured `FA_CONN`
/// line on stderr (and `FA_CONN_TRACE_FILE`), so a bench stall is
/// diagnosable from the live run log. Without the flag the chain is
/// byte-for-byte what it was.
http.Client sharedProviderHttpClient() {
  connTrace.configureFromEnv();
  return _sharedProviderClient ??=
      // gh-1395: the wrapper is a pass-through recorder with FA_CONN_DEBUG
      // off (E4: identical response objects); with the knob on it adds the
      // conn-open/first-byte trace lines (AC2). The pool semantics are
      // unchanged — the bench trace rides the same seam as the innermost
      // product.
      connTraceWrapProviderClient(
        providerHttpClientFactory?.call() ??
            connTrace.tracedClient() ??
            http.Client(),
        canInstallObserver: providerHttpClientFactory == null,
      );
}

/// Drops the shared keep-alive client: the NEXT [sharedProviderHttpClient]
/// call builds a fresh client and pool (gh-1395 AC5). Hygiene, not a
/// correctness fix — the eviction is flag-gated through
/// [maybeEvictProviderPool] (`FA_POOL_EVICTION`) and every existing
/// connection-level failure class already self-heals without it (the
/// stale_keepalive exoneration).
void resetSharedProviderHttpClient() {
  _sharedProviderClient?.close();
  _sharedProviderClient = null;
}

/// The effective connect watchdog: the config override or the default.
Duration get effectiveProviderConnectTimeout =>
    providerTimeoutsOverride?.connect ?? providerConnectTimeout;

/// The effective stream-idle watchdog: the config override or the default.
Duration get effectiveProviderStreamIdleTimeout =>
    providerTimeoutsOverride?.streamIdle ?? providerStreamIdleTimeout;

/// Connect/first-headers watchdog for NON-streaming provider fetches
/// (model lists, OAuth/token endpoints, quota probes): an endpoint that
/// never even answers headers fails fast instead of hanging the session
/// (issue #1036). Tighter than [providerConnectTimeout] on purpose — a
/// fetch is small, unlike a streamed generation.
const providerFetchConnectTimeout = Duration(seconds: 30);

/// Read watchdog for NON-streaming provider fetches: the whole response
/// (headers already arrived) must complete within this budget. The
/// `FA_PROVIDER_TIMEOUT_SECONDS` env override (folded into
/// [ProviderTimeoutsOverride.fetchRead] at boot) replaces this default.
const providerFetchReadTimeout = Duration(seconds: 120);

/// The effective fetch read watchdog: the override or the default.
Duration get effectiveProviderFetchReadTimeout =>
    providerTimeoutsOverride?.fetchRead ?? providerFetchReadTimeout;

/// The effective fetch connect watchdog: the 30s default capped by the
/// overall read budget — one knob ([effectiveProviderFetchReadTimeout])
/// tightens both legs.
Duration get effectiveProviderFetchConnectTimeout {
  final read = effectiveProviderFetchReadTimeout;
  return providerFetchConnectTimeout < read
      ? providerFetchConnectTimeout
      : read;
}

/// Sends a NON-streaming provider HTTP request under the fetch watchdogs
/// (issue #1036): connect/first-headers
/// ([effectiveProviderFetchConnectTimeout]) then the full body
/// ([effectiveProviderFetchReadTimeout]). On timeout throws a
/// [TimeoutException] whose message names [endpoint] — the caller surfaces
/// a clear, retryable error instead of hanging forever.
///
/// This is the bounded counterpart of [_sendWatched] for the call paths
/// streaming adapters never take. The connect leg cannot cancel the in-flight
/// socket (no headers, no response object — same ceiling as the streaming
/// connect watchdog); the read leg cancels the abandoned body subscription so
/// the socket is released back to the client instead of trickling into a
/// dead listener (the non-SSE twin of the issue-#921 abandonment).
Future<http.Response> sendProviderFetch(
  http.Client client,
  http.BaseRequest request, {
  String endpoint = 'provider endpoint',
}) async {
  final connect = effectiveProviderFetchConnectTimeout;
  final read = effectiveProviderFetchReadTimeout;
  final streamed = await client
      .send(request)
      .timeout(
        connect,
        onTimeout: () => throw TimeoutException(
          'provider fetch ($endpoint): no response headers within '
          '${connect.inSeconds}s (connect watchdog)',
        ),
      );
  // The read leg owns the body subscription directly: `Response.fromStream`
  // hides its listen, so on timeout the abandoned body would keep trickling
  // into a handlerless sink (the issue-#921 class). Owning the subscription
  // makes the watchdog's cancellation real.
  final body = BytesBuilder(copy: false);
  final completer = Completer<http.Response>();
  final subscription = streamed.stream.listen(
    body.add,
    onError: (Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer.complete(
          // The field set mirrors `Response.fromStream`.
          http.Response.bytes(
            body.takeBytes(),
            streamed.statusCode,
            request: request,
            headers: streamed.headers,
            isRedirect: streamed.isRedirect,
            persistentConnection: streamed.persistentConnection,
            reasonPhrase: streamed.reasonPhrase,
          ),
        );
      }
    },
  );
  return completer.future.timeout(
    read,
    onTimeout: () {
      // Detach so the socket closes (or returns to the keep-alive pool).
      unawaited(subscription.cancel().then((_) {}, onError: (Object _) {}));
      throw TimeoutException(
        'provider fetch ($endpoint): response did not complete within '
        '${read.inSeconds}s (read watchdog; FA_PROVIDER_TIMEOUT_SECONDS '
        'overrides this)',
      );
    },
  );
}

/// Wires an SSE [StreamIterator] over [response]'s body, cancelling the
/// subscription when [cancelToken] fires so the connection closes promptly.
///
/// The iterator carries an idle watchdog ([providerStreamIdleTimeout],
/// overridable in tests): a connected-but-silent endpoint raises a
/// [TimeoutException] the adapters surface as an error event. The timer
/// wraps each `moveNext` — NOT `Stream.timeout`: a `Stream.timeout` chained
/// after an `async*` transformer ([SseDecoder]) never fires (the generator
/// holds the subscription), and a byte-level timer resets on the
/// `: comment` heartbeat gateways use to keep wedged generations alive.
/// Event-level silence per `moveNext` is the honest signal.
///
/// The raw body subscription is owned here with a stable error sink
/// (issue #921): the `async*` [SseDecoder] cannot finish cancelling while
/// it is suspended awaiting input, so after the SSE iteration is abandoned
/// (idle watchdog, abort) the byte pipeline stays attached to the socket —
/// and a flaky link's late failure arriving in that window used to find a
/// handlerless chain and kill the process ('fa crashed: ClientException:
/// Connection closed while receiving data'). Late errors now land in the
/// owned `onError` and are swallowed once the stream is abandoned; live
/// errors ride into the pipeline for the adapter's try/catch. Done is
/// always forwarded: it is what unsticks the pending lazy cancellation.
StreamIterator<ServerSentEvent> createSseIterator(
  http.StreamedResponse response,
  CancelToken? cancelToken, {
  Duration? idleTimeout,
}) {
  final effectiveIdleTimeout =
      idleTimeout ?? effectiveProviderStreamIdleTimeout;
  var abandoned = false;
  void abandon() => abandoned = true;
  StreamSubscription<List<int>>? rawSub;
  final body = StreamController<List<int>>(
    onPause: () => rawSub?.pause(),
    onResume: () => rawSub?.resume(),
    onCancel: () {
      abandon();
      return rawSub?.cancel() ?? Future<void>.value();
    },
  );
  rawSub = response.stream.listen(
    (data) {
      // isClosed mirrors onError: a misbehaving source emitting after the
      // done forward would throw StateError inside this handler — the
      // same handlerless-crash class this sink exists to prevent.
      if (!abandoned && !body.isClosed) body.add(data);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (abandoned || (cancelToken?.isCancelled ?? false) || body.isClosed) {
        return; // the link's death rattle after abandonment — noise.
      }
      body.addError(error, stackTrace);
    },
    onDone: body.close,
  );
  final inner = StreamIterator(
    body.stream.transform(utf8.decoder).transform(const SseDecoder()),
  );
  final iterator = _IdleWatchdogSseIterator(
    inner,
    effectiveIdleTimeout,
    onAbandon: abandon,
    // gh-1395 (AC2/AC3): at FIRE time — before the abort completes — name
    // the idle stall (trace line) and dump the outbound payload
    // (StallSentinel).
    onStall: () => providerIdleStallFired(response, effectiveIdleTimeout),
  );
  if (cancelToken != null) {
    // cancel() is already quiet — no extra swallow needed here.
    unawaited(
      cancelToken.onCancel.then((_) {
        abandon();
        return iterator.cancel();
      }),
    );
  }
  return iterator;
}

/// [StreamIterator] wrapper that fails `moveNext` with a [TimeoutException]
/// after [idleTimeout] without a decoded SSE event, and cancels the inner
/// subscription on fire so the dead connection is released.
class _IdleWatchdogSseIterator implements StreamIterator<ServerSentEvent> {
  _IdleWatchdogSseIterator(
    this._inner,
    this._idleTimeout, {
    this.onAbandon,
    this.onStall,
  });

  final StreamIterator<ServerSentEvent> _inner;
  final Duration _idleTimeout;

  /// Called before any cancel so the byte sink starts swallowing late
  /// transport errors (issue #921).
  final void Function()? onAbandon;

  /// gh-1395: called AT watchdog fire, before the abort lands — the hook
  /// names the stall (ConnTrace) and dumps the outbound payload
  /// (StallSentinel). Null keeps the watchdog silent and cheap.
  final void Function()? onStall;

  Timer? _timer;

  @override
  ServerSentEvent get current => _inner.current;

  @override
  Future<bool> moveNext() {
    _timer?.cancel();
    final completer = Completer<bool>();
    final Future<bool> inner;
    try {
      inner = _inner.moveNext();
    } catch (error, stackTrace) {
      // Sync misuse throw (StreamIterator's 'Already waiting'): fail the
      // caller WITHOUT arming the timer — an orphaned timer would later
      // complete this completer unlistened in the root zone, the exact
      // crash class of issue #921.
      completer.completeError(error, stackTrace);
      return completer.future;
    }
    _timer = Timer(_idleTimeout, () {
      if (completer.isCompleted) return;
      // gh-1395: capture first — the dump is initiated while the request
      // state is still in scope, before the abort completes.
      onStall?.call();
      // Issue #1392 ConnTrace: the idle-watchdog fire is invisible today —
      // exactly why class-B's ~300s gaps are a guess. Name the idle span
      // and the current connection (single-flight bench contract) before
      // the abort lands.
      connTrace.idleWatchdogFired(
        idleSec: _idleTimeout.inMicroseconds / 1e6,
        connAgeSec: connTrace.lastConnAgeSec,
        localPort: connTrace.lastLocalPort,
      );
      // Abandon before cancelling so the byte sink swallows the dying
      // link's error, and quiet-cancel: the cancel future rides that
      // dying pipeline and may itself fail (issue #921).
      onAbandon?.call();
      unawaited(_quietCancel(_inner.cancel()));
      completer.completeError(
        TimeoutException(
          'no events from the endpoint for '
          '${_idleTimeout.inSeconds}s (stream idle timeout)',
          _idleTimeout,
        ),
      );
    });
    unawaited(
      inner.then(
        (value) {
          _timer?.cancel();
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          _timer?.cancel();
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      ),
    );
    return completer.future;
  }

  @override
  Future<void> cancel() {
    _timer?.cancel();
    onAbandon?.call();
    // The quieted future IS the contract: the abandoned pipeline is by
    // definition noise, so a caller's `await iterator.cancel()` can never
    // see a dying-pipeline cancel failure (issue #921).
    return _quietCancel(_inner.cancel());
  }
}

/// Awaits a cancellation whose pipeline may be dying: its failure is noise
/// (issue #921) — swallowed, never an unawaited-error crash.
Future<void> _quietCancel(Future<void> cancel) {
  return cancel.then((_) {}, onError: (Object _) {});
}

/// Mutable accumulation state for one streamed assistant message.
///
/// pi mutates a single `output` object; Dart types are immutable, so adapters
/// keep the pieces here and build an immutable [snapshot] per event instead
/// (same partial-first contract).
final class ProviderStreamState {
  /// Creates stream state for [model].
  ProviderStreamState(this.model);

  /// The model being called.
  final Model model;

  /// Ordered content blocks accumulated so far.
  final blocks = <StreamingBlock>[];

  /// When the stream started (pi stores Unix milliseconds).
  final timestamp = DateTime.now();

  /// Token/cost accounting as last reported by the provider.
  var usage = Usage.zero;

  /// Why the stream terminated (best guess until the terminal event).
  var stopReason = StopReason.stop;

  /// The provider's raw stop/finish reason string as reported on the wire,
  /// when the adapter parsed one (see [AssistantMessage.rawStopReason]).
  String? rawStopReason;

  /// Failure description for error/aborted terminal events.
  String? errorMessage;

  /// The structured 429 decode (issue #867), set only by the terminal
  /// error path; carried onto the finalized [AssistantMessage].
  RateLimitInfo? rateLimit;

  /// Provider-specific response/message identifier, when exposed upstream.
  String? responseId;

  /// Concrete model id reported by the provider, when different from the
  /// requested one (e.g. OpenRouter `auto` routing).
  String? responseModel;

  /// Builds the immutable [AssistantMessage] carried by event snapshots.
  ///
  /// With [finalize] the blocks strip streaming scratch state (used for the
  /// terminal error snapshot after an abort or failure mid-stream).
  AssistantMessage snapshot({bool finalize = false}) => AssistantMessage(
    content: [
      for (final block in blocks) block.toContentBlock(finalize: finalize),
    ],
    api: model.api,
    provider: model.provider,
    model: model.id,
    responseModel: responseModel,
    responseId: responseId,
    usage: usage,
    stopReason: stopReason,
    rawStopReason: rawStopReason,
    errorMessage: errorMessage,
    rateLimit: rateLimit,
    timestamp: timestamp,
  );
}

/// Mutable streaming accumulation for one content block. Converted into an
/// immutable [ContentBlock] for every event snapshot.
sealed class StreamingBlock {
  /// Converts to the immutable [ContentBlock] carried by event snapshots.
  ///
  /// With [finalize] the block strips streaming scratch state (used for the
  /// terminal error snapshot after an abort or failure mid-stream).
  ContentBlock toContentBlock({bool finalize = false});
}

/// Accumulating text content block.
final class TextStreamingBlock extends StreamingBlock {
  /// Provider-specific opaque signature for this block (Google
  /// `thoughtSignature` on a text part), when reported.
  String? textSignature;

  /// The accumulated text.
  final text = StringBuffer();

  @override
  ContentBlock toContentBlock({bool finalize = false}) {
    return TextContent(text: text.toString(), textSignature: textSignature);
  }
}

/// Accumulating thinking (reasoning) content block.
final class ThinkingStreamingBlock extends StreamingBlock {
  /// Creates a thinking block.
  ///
  /// [signature] is the provider-specific thinking signature, when known up
  /// front (OpenAI-style reasoning field name); Anthropic accumulates it via
  /// `signature_delta` events instead and mutates [signature]. [initialText]
  /// seeds fixed text (Anthropic redacted thinking).
  ThinkingStreamingBlock({
    this.signature,
    this.redacted = false,
    String initialText = '',
  }) {
    thinking.write(initialText);
  }

  /// The thinking signature, if any.
  String? signature;

  /// Whether the thinking content was redacted by safety filters (Anthropic
  /// `redacted_thinking`; the opaque payload sits in [signature]).
  final bool redacted;

  /// The accumulated thinking text.
  final thinking = StringBuffer();

  @override
  ContentBlock toContentBlock({bool finalize = false}) {
    return ThinkingContent(
      thinking: thinking.toString(),
      thinkingSignature: signature,
      redacted: redacted,
    );
  }
}

/// Accumulating tool-call block with partial JSON arguments.
final class ToolCallStreamingBlock extends StreamingBlock {
  /// Creates a tool-call block.
  ToolCallStreamingBlock({
    required this.id,
    required this.name,
    this.streamIndex,
    this.initialArguments,
  });

  /// Provider-assigned tool call id.
  String id;

  /// Name of the tool to invoke.
  String name;

  /// The provider's stream index for this call (OpenAI `tool_calls[].index`),
  /// when the protocol identifies blocks by index rather than id.
  int? streamIndex;

  /// Provider-specific opaque thought signature (OpenRouter encrypted
  /// reasoning detail attached to this call).
  String? thoughtSignature;

  /// Arguments already parsed by the provider at block start (Anthropic
  /// `tool_use` blocks can carry a complete `input`). Used when no argument
  /// deltas ever arrive.
  final Map<String, dynamic>? initialArguments;

  /// The accumulated raw JSON argument text.
  final partialArgs = StringBuffer();

  /// Parsed arguments, filled in by [finish].
  Map<String, dynamic> arguments = const <String, dynamic>{};

  /// Whether [finish] has run (the block's end event was seen).
  var finished = false;

  /// Parses the accumulated [partialArgs] into [arguments] and marks the
  /// block finished. Called when the provider signals the block's end.
  void finish() {
    arguments = partialArgs.isEmpty && initialArguments != null
        ? initialArguments!
        : parseStreamingJson(partialArgs.toString());
    finished = true;
  }

  @override
  ContentBlock toContentBlock({bool finalize = false}) {
    if (finalize && !finished) {
      // Stream ended before the block's end event (error/abort): best-effort
      // parse and strip the scratch buffer, mirroring pi's catch block.
      return ToolCall(
        id: id,
        name: name,
        arguments: partialArgs.isEmpty && initialArguments != null
            ? initialArguments!
            : parseStreamingJson(partialArgs.toString()),
        thoughtSignature: thoughtSignature,
      );
    }
    if (finished) {
      return ToolCall(
        id: id,
        name: name,
        arguments: arguments,
        thoughtSignature: thoughtSignature,
      );
    }
    return ToolCall(
      id: id,
      name: name,
      arguments: const <String, dynamic>{},
      thoughtSignature: thoughtSignature,
      partialArguments: partialArgs.toString(),
    );
  }
}

/// Pushes the end event for [block] (text, thinking, or tool call) at its
/// position in [blocks].
///
/// Shared by the adapters: pi fires `text_end` / `thinking_end` /
/// `toolcall_end` identically across providers.
void pushBlockEndEvent(
  AssistantMessageEventStream eventStream,
  List<StreamingBlock> blocks,
  StreamingBlock block,
  AssistantMessage Function() snapshot,
) {
  final index = blocks.indexOf(block);
  if (index == -1) {
    return;
  }
  switch (block) {
    case TextStreamingBlock():
      eventStream.push(
        TextEndEvent(
          contentIndex: index,
          content: block.text.toString(),
          partial: snapshot(),
        ),
      );
    case ThinkingStreamingBlock():
      eventStream.push(
        ThinkingEndEvent(
          contentIndex: index,
          content: block.thinking.toString(),
          partial: snapshot(),
        ),
      );
    case ToolCallStreamingBlock():
      block.finish();
      final partial = snapshot();
      eventStream.push(
        ToolCallEndEvent(
          contentIndex: index,
          toolCall: partial.content[index] as ToolCall,
          partial: partial,
        ),
      );
  }
}

/// Converts a caught [error] into the terminal `ErrorEvent`
/// (errors-as-events invariant): aborts get [StopReason.aborted], everything
/// else [StopReason.error].
void pushStreamErrorEvent(
  AssistantMessageEventStream eventStream,
  ProviderStreamState state,
  Object error,
  CancelToken? cancelToken,
) {
  final aborted =
      error is AbortedError ||
      error is CancelledException ||
      (cancelToken?.isCancelled ?? false);
  final reason = aborted ? StopReason.aborted : StopReason.error;
  state.stopReason = reason;
  state.errorMessage = aborted
      ? 'Request was aborted'
      : formatProviderError(error);
  // Issue #867: the structured 429 rides on the finalized message so every
  // surface renders from the structure; the raw payload stays inside.
  state.rateLimit = aborted || error is! ProviderHttpError
      ? null
      : error.rateLimit;
  final retryAfter = !aborted && error is ProviderHttpError
      ? error.retryAfter
      : null;
  eventStream.push(
    ErrorEvent(
      reason: reason,
      error: state.snapshot(finalize: true),
      retryAfter: retryAfter,
    ),
  );
}

/// Runs a provider adapter's streaming [body] under the shared terminal
/// protocol: any caught error becomes an `ErrorEvent` via
/// [pushStreamErrorEvent] (errors-as-events invariant), the stream is always
/// ended, and the owned HTTP client is closed.
///
/// pi wraps each adapter body in the same try/catch; the wrapper exists so
/// the adapters do not duplicate it.
Future<void> runProviderStream(
  AssistantMessageEventStream eventStream,
  ProviderStreamState state,
  CancelToken? cancelToken,
  http.Client httpClient, {
  required bool ownsClient,
  required Future<void> Function() body,
}) async {
  try {
    await body();
  } catch (error) {
    pushStreamErrorEvent(eventStream, state, error, cancelToken);
  } finally {
    eventStream.end();
    if (ownsClient) {
      httpClient.close();
    }
  }
}

/// Sends [request] (via [sendProviderRequest]), runs the adapter's
/// `onResponse` hook, and pushes the `StartEvent` with the initial snapshot.
///
/// Shared by the adapters: pi fires `start` right after the response headers
/// arrive, before the body stream is consumed.
Future<http.StreamedResponse> startProviderResponse(
  AssistantMessageEventStream eventStream,
  ProviderStreamState state,
  http.Client httpClient,
  http.Request request,
  CancelToken? cancelToken,
  FutureOr<void> Function(int statusCode, Map<String, String> headers, Model)?
  onResponse,
) async {
  final response = await sendProviderRequest(httpClient, request, cancelToken);
  await onResponse?.call(response.statusCode, response.headers, state.model);
  eventStream.push(StartEvent(partial: state.snapshot()));
  return response;
}
