/// Payload-aware stall handling (issue #1916): multi-MB image-heavy
/// submits need more first-token patience than a text session, and a
/// provider that keeps choking on the SAME huge payload must produce one
/// actionable warning — never an endless silent retry loop.
///
/// Three seams, pure Dart (no I/O), all host-wired like the existing
/// notice globals:
///
/// - [scaleStallWindowForPayload] widens a stall window (connect watchdog
///   in `provider_common.dart`, run-idle watchdog in `agent.dart`) for the
///   outbound payload size — a ~20MB upload gets up to 2x the patience,
///   capped so genuine hangs stay bounded. An explicit user-declared
///   connect budget is a clamp (gh-1617 AC4) and is never scaled; the
///   run-idle window scales AFTER its explicit-vs-floor resolution.
/// - [noteOutboundEstimate] / [lastOutboundEstimateBytes] — the request
///   build (via `rewriteRequestImages`, so the agent-loop god file adds no
///   lines) publishes its outbound size; the run-idle arm reads it.
/// - [payloadStallLatch] — repeated stalls of one payload fingerprint
///   (endpoint+size, or model+estimate) fire [payloadStallAdvice] ONCE
///   with the /compact + image-budget remedy. A different payload resets
///   the streak: the warning is about re-uploading the SAME bytes.
library;

import '../context.dart';
import '../types.dart';

/// Payload size below which stall windows never scale: a text-session
/// request keeps today's windows byte-for-byte.
const int payloadStallFreeBytes = 1024 * 1024;

/// Payload size at which the scale tops out at [maxPayloadStallScale].
const int payloadStallFullScaleBytes = 16 * 1024 * 1024;

/// The widest stall window a payload can buy: 2x. Genuine hangs must stay
/// bounded even for 100MB requests.
const double maxPayloadStallScale = 2.0;

/// The linear payload scale factor for [bytes]: 1.0 up to
/// [payloadStallFreeBytes], rising to [maxPayloadStallScale] at
/// [payloadStallFullScaleBytes] (16MB+ uploads all get 2x).
double payloadStallScaleFor(int bytes) {
  if (bytes <= payloadStallFreeBytes) return 1.0;
  final span = payloadStallFullScaleBytes - payloadStallFreeBytes;
  final t = ((bytes - payloadStallFreeBytes) / span).clamp(0.0, 1.0);
  return 1.0 + t * (maxPayloadStallScale - 1.0);
}

/// [window] widened for an outbound payload of [bytes] (1MB free, 2x at
/// 16MB, capped).
Duration scaleStallWindowForPayload(Duration window, int bytes) => Duration(
  milliseconds: (window.inMilliseconds * payloadStallScaleFor(bytes)).round(),
);

/// A rough outbound-payload size for [messages]: the sum of every text
/// surface plus every image payload (base64 chars ≈ wire bytes 1:1). Tool
/// arguments are skipped — the MB scale that moves stall windows lives in
/// image blobs and long text, never in JSON tool args.
int estimateOutboundBytes(List<Message> messages) {
  var bytes = 0;
  for (final message in messages) {
    switch (message) {
      case UserMessage(:final content):
        if (content is String) {
          bytes += content.length;
        } else if (content is List<ContentBlock>) {
          bytes += _blocksBytes(content);
        }
      case AssistantMessage(:final content):
        bytes += _blocksBytes(content);
      case ToolResultMessage(:final content):
        bytes += _blocksBytes(content);
      default:
        break;
    }
  }
  return bytes;
}

int _blocksBytes(List<ContentBlock> blocks) {
  var bytes = 0;
  for (final block in blocks) {
    switch (block) {
      case TextContent(:final text):
        bytes += text.length;
      case ImageContent(:final data):
        bytes += data.length;
      case ThinkingContent(:final thinking):
        bytes += thinking.length;
      default:
        break;
    }
  }
  return bytes;
}

/// The last request build's outbound-size estimate — read by the run-idle
/// watchdog when it arms (zero until the first request build; a kill
/// switch or image-free fast path still publishes, so the estimate never
/// goes stale across a registry toggle).
int lastOutboundEstimateBytes = 0;

/// Published once per request build by `rewriteRequestImages` — the one
/// place every provider call already funnels through.
void noteOutboundEstimate(List<Message> messages) =>
    lastOutboundEstimateBytes = estimateOutboundBytes(messages);

/// The one actionable payload-stall warning (issue #1916 AC3): fired ONCE
/// per stalled payload fingerprint after [PayloadStallLatch.threshold]
/// consecutive stalls. [bytes] is the stalled payload's size estimate.
typedef PayloadStallAdviceNotice = void Function(int bytes, String fingerprint);

/// Host-wired like the other notice globals (`transientRetryNotice`): the
/// CLI prints a dim `[net]` line + fa.log entry; hosts leaving it null stay
/// silent (the latch still runs — semantics never depend on the wiring).
PayloadStallAdviceNotice? payloadStallAdvice;

/// Consecutive same-payload stalls before the advice fires: the first
/// stall may be a blip; the second identical one is the livelock shape.
const int payloadStallAdviceThreshold = 2;

/// The latch behind "ONE actionable warning instead of endless
/// same-payload retries" (issue #1916 AC3). Single-slot by design
/// (`// ponytail:`): the livelock is ONE payload re-uploaded over and
/// over; a map only if multi-payload interleaving ever matters.
final class PayloadStallLatch {
  String? _fingerprint;
  int _streak = 0;
  bool _advised = false;

  /// Records one stall of [fingerprint]. Fires [payloadStallAdvice] once
  /// when the same fingerprint reaches [payloadStallAdviceThreshold].
  void noteStall(String fingerprint, int bytes) {
    if (_fingerprint != fingerprint) {
      _fingerprint = fingerprint;
      _streak = 0;
      _advised = false;
    }
    if (_advised) return;
    if (++_streak < payloadStallAdviceThreshold) return;
    _advised = true;
    payloadStallAdvice?.call(bytes, fingerprint);
  }

  /// New run: the next stall sequence starts fresh.
  void reset() {
    _fingerprint = null;
    _streak = 0;
    _advised = false;
  }
}

/// The process-wide latch (the stall paths are host-global seams already).
final PayloadStallLatch payloadStallLatch = PayloadStallLatch();

/// The rendered advice — the remedy line hosts surface verbatim.
String payloadStallAdviceLine(int bytes) =>
    'stalled repeatedly on the same ~${(bytes / (1024 * 1024)).toStringAsFixed(0)}MB '
    'request before any response — the provider is choking on the payload: '
    '/compact to drop image data, lower images.maxBytesPerRequest '
    '(see /images), or /restart as a last resort';
