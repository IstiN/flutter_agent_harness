/// Session image registry (issue #171): unique images ride a provider
/// request exactly ONCE; every later occurrence in the kept window becomes
/// a stable text reference `[Image N]`.
///
/// The registry is DERIVED state, rebuilt from the request's message
/// window on every provider call — the session JSONL keeps message records
/// exactly as today (byte-level invariant I1), and the same window always
/// rebuilds the same registry (determinism I2). Request-assembly rules:
///
/// - Image content blocks in history (user messages and tool results) are
///   swapped for `[Image N]` text refs; the unique original rides in a
///   dedicated carrier user message `[TextBlock("[Image N]"), ImageBlock]`
///   inserted before the first referencing user message, or after the
///   tool-result run when the first reference lives in a tool result
///   (nothing may sit between a tool call and its result on the wire).
/// - The CURRENT user message (the last one in the window) always rides
///   its images in place, never as references (I3) — the model must see
///   what the user just sent; each in-place image carries its `[Image N]`
///   label so the model can cite it back (F3).
/// - A per-request cap on unique images and a per-request byte budget on
///   image payloads (`images.maxPerRequest` + `images.maxBytesPerRequest`,
///   issue #1916) drop by priority (current > newest history > older
///   history); every drop is reported through the drop notice — never
///   silent, with the reason (count or bytes) named.
/// - History text that carries a whole image as an inline `data:image/…`
///   URL (legacy shapes — issue #1916 AC2) is folded into a real image
///   block first, so those bytes ride the same once-only registry path
///   instead of replaying raw forever.
/// - No dangling refs (I4): an `[Image N]` mention whose original is not
///   in the request (compacted away, outside the window, or dropped by
///   the cap) resolves to the plain-text note [unavailableImageNote].
///   Authored citations in history are trusted only while the window was
///   never renumbered: once a compaction/trim boundary appears, history
///   citations degrade to the note too — after eviction the number may
///   name a DIFFERENT image, and a silent rebind would be wrong data
///   (F2). The current message is authored after the last renumbering and
///   stays trusted.
///
/// Mechanics ported from learn.ai's production Go engine
/// (`solution_chat/v2/core/workflow.go`): content-key dedup, first-seen
/// indexing, the `allowNew`-style cap gate, and resilient mention
/// resolution.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../context.dart';
import '../providers/payload_stall.dart' show noteOutboundEstimate;
import '../skills/operative_pins.dart' show isPinRenumberingBoundary;
import '../types.dart';

/// Default per-request cap on unique images (`images.maxPerRequest`).
/// Generous enough that ordinary sessions never hit it; photo-heavy long
/// threads stay flat instead of growing linearly. ~20 inline images is
/// well inside every current vision model's budget.
const defaultMaxImagesPerRequest = 20;

/// Default per-request byte budget on image payloads
/// (`images.maxBytesPerRequest`, issue #1916): ~8MB of base64 — sane for
/// slow uplinks, where a max-count batch of screenshots (~26MB) blew the
/// stall watchdogs and livelocked the submit. Base64 chars are wire bytes
/// 1:1, so the budget IS the upload size.
const int defaultMaxImageBytesPerRequest = 8 * 1024 * 1024;

/// The note replacing image refs whose original is not in the request
/// (compaction interplay / cap drops — never a dangling ref).
const unavailableImageNote = '(image no longer available)';

/// The reference grammar: `[Image 3]` inline text.
final RegExp imageRefPattern = RegExp(r'\[Image (\d+)\]');

/// Renders the reference label for [index].
String imageRefLabel(int index) => '[Image $index]';

/// Settings for the `images:` config section (`~/.fah/config.yaml`).
final class ImageRegistryConfig {
  const ImageRegistryConfig({
    this.enabled = true,
    this.maxPerRequest = defaultMaxImagesPerRequest,
    this.maxBytesPerRequest = defaultMaxImageBytesPerRequest,
    this.perModel = const {},
  });

  /// Kill switch: `images.registry: false` reproduces today's request
  /// shape byte-for-byte (no rewrite at all).
  final bool enabled;

  /// Per-request cap on unique images (`images.maxPerRequest`).
  final int maxPerRequest;

  /// Per-request byte budget on image payloads
  /// (`images.maxBytesPerRequest`, issue #1916) — layered onto
  /// [maxPerRequest]: whichever limit binds first drops the image.
  final int maxBytesPerRequest;

  /// Per-model cap overrides (`images.perModel.<modelId>`, issue #1750):
  /// user truth beats the catalog and the global default; a
  /// ceiling-setter only — never raises a cap above provider reality.
  final Map<String, int> perModel;
}

/// Process-wide image-registry settings, published by hosts at boot from
/// the `images:` config section (same pattern as
/// `providerTimeoutsOverride`): the rewrite happens deep inside the agent
/// loop's request build, far from any host config object.
ImageRegistryConfig imageRegistryConfig = const ImageRegistryConfig();

/// Why a request dropped an image (issue #1916 AC1): the count cap
/// (`images.maxPerRequest`) or the byte budget
/// (`images.maxBytesPerRequest`) — surfaces name which. gh-1934 adds the
/// eviction class: images replaced by placeholders because the payload
/// was evicted (compaction boundary / 413 recovery), not because a cap
/// bound.
enum ImageDropReason {
  /// The per-request unique-image count cap bound first.
  count,

  /// The per-request base64 byte budget bound first.
  bytes,

  /// gh-1934: the image was EVICTED to a placeholder — every image block
  /// outside the current message once a renumbering boundary sits in the
  /// window (compaction eviction, AC2), every image block period under
  /// the 413 recovery strip-all, or a session-latched evicted key.
  evicted,
}

/// One image dropped by the per-request cap (issue #1889): the registry
/// label index, the full content key (detail surfaces only — default
/// notice lines carry previews at most), and whether the dropped
/// occurrence sat in the CURRENT user message (just attached — actionable)
/// rather than in history (expected long-session degradation).
final class ImageDropEvent {
  const ImageDropEvent({
    required this.index,
    required this.key,
    required this.fromCurrentMessage,
    this.reason = ImageDropReason.count,
  });

  /// The `[Image N]` index of the dropped image.
  final int index;

  /// Full content key of the dropped image.
  final String key;

  /// Whether the dropped occurrence sat in the current user message.
  final bool fromCurrentMessage;

  /// Which limit bound first (#1916 AC1).
  final ImageDropReason reason;

  /// Short stable preview of the content key.
  String get keyPreview => imageKeyPreview(key);
}

/// Everything one request build decided about the image cap (issue
/// #1889): the per-image drops, the effective cap (post-#1750 learned
/// overrides included), the model it resolved for, and the window totals.
/// Fired ONCE per request build — even with zero drops — so hosts can
/// aggregate, latch, and detect recovery; the stateless registry itself
/// stays stateless.
final class ImageDropReport {
  const ImageDropReport({
    required this.drops,
    required this.cap,
    required this.modelId,
    required this.currentImageCount,
    required this.registryCount,
    required this.ridingCount,
    this.maxBytes = 0,
    this.strippedCount = 0,
    this.evictedCount = 0,
  });

  /// Every dropped image of the request, in drop order.
  final List<ImageDropEvent> drops;

  /// The effective per-request cap this request was built under.
  final int cap;

  /// The model id the cap resolved for (part of the latch identity).
  final String modelId;

  /// Unique images in the current user message (rode or dropped).
  final int currentImageCount;

  /// Unique images in the whole window (the registry size).
  final int registryCount;

  /// Images that rode the request (`registryCount - drops` when the
  /// current batch fit under the cap; kept explicit for the surface).
  final int ridingCount;

  /// The byte budget the request was built under (#1916 AC1); 0 = no
  /// budget info (legacy constructors) — surfaces omit byte mentions.
  final int maxBytes;

  /// gh-1934: unique images replaced by placeholders under the 413
  /// recovery strip-all in this build (0 = no strip ran).
  final int strippedCount;

  /// gh-1934: unique images evicted to placeholders by the compaction
  /// boundary rule or a session-latched evicted key (0 = none).
  final int evictedCount;
}

/// Set by hosts that surface drops (the CLI aggregates + latches into one
/// transcript notice and logs every per-image detail to fa.log; the app
/// mirrors that onto AppLog + a chat chip). Fired once per request build.
/// Same pattern as `transientRetryNotice`.
typedef ImageDropReportNotice = void Function(ImageDropReport report);

/// The active per-request drop reporter — wired once by the host at boot.
ImageDropReportNotice? imageDropReportNotice;

/// Host-visible learned-cap notice (issue #1750): fired ONCE when a
/// provider image-count refusal teaches the loop a smaller cap — names
/// the model and the learned cap before the per-image drop lines follow.
/// Same pattern as [imageDropNotice].
typedef ImageCapLearnedNotice = void Function(String modelId, int cap);

/// Set by hosts that surface the adaptive re-send (the CLI prints a dim
/// transcript line + logs to fa.log).
ImageCapLearnedNotice? imageCapLearnedNotice;

/// The cap-resolution seam (issue #1750): `perModel config > catalog
/// maxImages > images.maxPerRequest` — first level present wins, the
/// same shape as the scoped provider timeouts (issue #1554). [perModel]
/// null reads the process-wide [imageRegistryConfig] section.
int resolveImageCap({
  String? modelId,
  int? catalogMaxImages,
  Map<String, int>? perModel,
}) {
  final override = modelId == null
      ? null
      : (perModel ?? imageRegistryConfig.perModel)[modelId];
  if (override != null) return override;
  return catalogMaxImages ?? imageRegistryConfig.maxPerRequest;
}

/// The runtime latch key of a model's learned image cap: (provider,
/// model) — a mid-run `/model` switch to another pair never sees it (E2).
String imageCapLatchKey(String provider, String modelId) =>
    '$provider|$modelId';

/// One unique image in the window.
final class ImageRegistryEntry {
  const ImageRegistryEntry({
    required this.index,
    required this.key,
    required this.data,
    required this.mimeType,
  });

  /// First-seen-order index inside the window (the `N` of `[Image N]`).
  final int index;

  /// Content key of the canonical payload string.
  final String key;

  /// Base64 payload (data-URL bytes).
  final String data;

  /// Mime type of the payload.
  final String mimeType;
}

/// The per-window image registry: content-keyed, rebuilt deterministically
/// from a message list (issue #171 I2).
final class ImageRegistry {
  const ImageRegistry._(this._entries);

  final List<ImageRegistryEntry> _entries;

  /// Scans [messages] (oldest first) assigning indexes in first-seen
  /// order over every image-bearing user message and tool result.
  static ImageRegistry scan(List<Message> messages) {
    final entries = <ImageRegistryEntry>[];
    final seen = <String>{};
    for (final message in messages) {
      for (final image in _imagesOf(message)) {
        final key = imageContentKey(image);
        if (seen.add(key)) {
          entries.add(
            ImageRegistryEntry(
              index: entries.length,
              key: key,
              data: image.data,
              mimeType: image.mimeType,
            ),
          );
        }
      }
    }
    return ImageRegistry._(entries);
  }

  /// Number of unique images in the window.
  int get length => _entries.length;

  /// The `{content key → index}` map (deterministic for one window).
  Map<String, int> get indexByKey => {
    for (final entry in _entries) entry.key: entry.index,
  };
}

/// Content key of an image: SHA-256 over the canonical payload string
/// (`data:<mime>;base64,<data>`). Same bytes under a different mime are
/// distinct entries (re-encoded occurrences dedup-miss — correct but
/// suboptimal, learn.ai's resilient-lookup semantics).
String imageContentKey(ImageContent image) => sha256
    .convert(utf8.encode('data:${image.mimeType};base64,${image.data}'))
    .toString();

/// The agent loop's request-payload image rewrite (#171 + #1889 + #1916 +
/// gh-1934): the kill switch skips it entirely (byte-identical legacy — no
/// rewrite, no reports), the cap resolves per model (`#1750` learned latch >
/// `perModel` config > catalog maxImages > the global maxPerRequest), the
/// byte budget resolves per session (`images.maxBytesPerRequest`, lowered
/// by the 413 recovery state's learned budget), and the host-facing seam is
/// the per-request [ImageDropReport] (one call per build, zero drops
/// included). Also publishes the outbound-size estimate for the
/// payload-aware stall watchdogs ([noteOutboundEstimate] — every provider
/// call funnels through here, so the estimate never goes stale). Lives
/// beside the seam it fans out to so the loop's call site stays one
/// expression. [recovery] (gh-1934) arms the compaction/413 eviction rules
/// and feeds the build's drop/strip counts back to the recovery state.
List<Message> rewriteRequestImages(
  List<Message> messages, {
  required String modelId,
  required int? catalogMaxImages,
  required int? capOverride,
  ImagePayloadRecoveryState? recovery,
}) {
  noteOutboundEstimate(messages);
  if (!imageRegistryConfig.enabled) return messages;
  final configuredBytes = imageRegistryConfig.maxBytesPerRequest;
  return rewriteHistoryImages(
    messages,
    maxPerRequest:
        capOverride ??
        resolveImageCap(modelId: modelId, catalogMaxImages: catalogMaxImages),
    maxBytesPerRequest:
        recovery?.effectiveByteBudget(configuredBytes) ?? configuredBytes,
    modelId: modelId,
    onReport: (report) {
      recovery?.observeBuild(
        dropped: report.drops
            .where((drop) => drop.reason == ImageDropReason.bytes)
            .length,
        stripped: report.strippedCount,
      );
      imageDropReportNotice?.call(report);
    },
    stripAll: recovery?.stripAll ?? false,
    evictedKeys: recovery?.evictedKeys,
  );
}

/// A short, stable preview of a content key for drop notices.
String imageKeyPreview(String key) => key.substring(0, 8);

/// The placeholder replacing an evicted image block (gh-1934): names the
/// same 8-hex content-key preview the drop notices and `/images` carry —
/// an honest label, never a silent rebinding of `[Image N]` numbers (AC7).
String imageDroppedPlaceholder(String key) =>
    '[image dropped: ${imageKeyPreview(key)}]';

/// The text-embedded image shape (issue #1916 AC2): legacy session
/// records, pre-#171 transcripts and hosts that paste screenshots as
/// markdown carry screenshots INSIDE TextContent as a `data:image/…`
/// URL — invisible to the ImageContent scan, so the raw bytes replayed
/// on every request forever (the #1916 evidence: 9 history user
/// messages, 14.2MB, 1 registered image block).
final RegExp _embeddedImagePattern = RegExp(
  r'data:image/(png|jpeg|jpg|gif|webp);base64,([A-Za-z0-9+/=]+)',
);

/// Text data-URL payloads smaller than this are left as text: icons and
/// separators are legitimate inline content; the MB-scale screenshot
/// blobs are what must never replay.
const int embeddedImageMinChars = 64 * 1024;

/// Rewrites the OUTGOING request payload (never the transcript): image
/// blocks become `[Image N]` refs, unique originals ride once as carriers,
/// the current user message rides in place, and the per-request caps drop
/// by priority (current > newest > older) reporting every drop.
///
/// [onReport] fires ONCE per call with the request's [ImageDropReport]
/// (zero drops included, once the rewrite engaged) — the seam the hosts'
/// aggregation+latch layer consumes (issue #1889). The image-free
/// fast path (nothing to rewrite) skips it: an image-free session pays
/// nothing and never registers as a drop-situation change.
///
/// gh-1934 eviction rules (payload-only — the transcript keeps the bytes):
/// - [stripAll] (the 413 ladder's pass 2) replaces EVERY image block
///   period — current message included — with the
///   `[image dropped: <key preview>]` placeholder.
/// - When the window carries a renumbering boundary (compaction summary /
///   structured marker / local-trim note), every HISTORY image block
///   outside the current user message is evicted the same way (AC2):
///   /compact provably restores sendability on a poisoned session, the
///   placeholders ride token accounting, and no boundary can re-carriage
///   old image bytes.
/// - [evictedKeys] pins additional content keys to the placeholder (the
///   session recovery latch).
///
/// Returns the SAME list instance when there is nothing to rewrite (no
/// images and no `[Image N]` mentions), so image-free sessions pay
/// nothing.
List<Message> rewriteHistoryImages(
  List<Message> messages, {
  int? maxPerRequest,
  int? maxBytesPerRequest,
  String? modelId,
  void Function(ImageDropReport report)? onReport,
  bool stripAll = false,
  Set<String>? evictedKeys,
}) {
  final currentIdx0 = _lastUserMessageIndex(messages);
  // #1916 AC2 pre-pass: fold text-embedded data-URL images into real
  // ImageContent blocks on HISTORY messages — the scan, dedup, caps and
  // refs below then treat them exactly like pasted images, and legacy
  // shapes can never replay raw bytes again. The current message keeps
  // its text verbatim (I3) — it degrades on the NEXT turn.
  var normalized = messages;
  for (var i = 0; i < messages.length; i++) {
    if (i == currentIdx0) continue;
    final (folded, changed) = _extractEmbeddedImages(messages[i]);
    if (!changed) continue;
    if (identical(normalized, messages)) normalized = List.of(messages);
    normalized[i] = folded;
  }
  var hasImages = false;
  for (final message in normalized) {
    if (_imagesOf(message).isNotEmpty) {
      hasImages = true;
      break;
    }
  }
  if (!hasImages && !normalized.any(_mentionsImageRef)) {
    // Nothing to rewrite: return the CALLER'S list instance (the
    // image-free fast-path guarantee) even when the fold pre-pass ran.
    return messages;
  }

  // F2 pre-pass: when the window carries a renumbering boundary, history
  // citations may name a different image than their number does now —
  // degrade AUTHORED text mentions before assembly. Block rewrites,
  // carrier labels and the current message are generated content-keyed
  // (or provably fresh) and must survive.
  final degraded = normalized.any(_isRenumberingBoundary)
      ? [
          for (var i = 0; i < normalized.length; i++)
            i == currentIdx0
                ? normalized[i]
                : _resolveMentions(
                    normalized[i],
                    const <int>{},
                    trusted: false,
                  ),
        ]
      : normalized;
  final cap = maxPerRequest ?? imageRegistryConfig.maxPerRequest;
  final maxBytes = maxBytesPerRequest ?? imageRegistryConfig.maxBytesPerRequest;
  final entryByKey = <String, ImageRegistryEntry>{};
  final occurrences = <String, List<int>>{};
  _scanImages(degraded, entryByKey, occurrences);
  final currentIdx = _lastUserMessageIndex(degraded);
  final riding = _selectRiding(
    degraded,
    entryByKey,
    occurrences,
    currentIdx,
    cap,
    maxBytes,
  );
  final carriers = _planCarriers(degraded, entryByKey, occurrences, riding);

  // Emit: rewritten history (image blocks → refs/notes), the current
  // message in place with fresh `[Image N]` labels (F3), carriers at
  // their anchors.
  final out = _emitRewritten(degraded, currentIdx, riding, carriers);

  // Mention pass (I4): every remaining `[Image N]` in text that does not
  // resolve to a riding index becomes the unavailable note. Authored
  // history citations were already degraded by the pre-pass; what
  // survives here is generated content-keyed text.
  final ridingIndexes = riding.indexByKey.values.toSet();
  final rewritten = [
    for (final message in out) _resolveMentions(message, ridingIndexes),
  ];
  onReport?.call(
    ImageDropReport(
      drops: riding.drops,
      cap: cap,
      modelId: modelId ?? '',
      currentImageCount: riding.currentImageCount,
      registryCount: entryByKey.length,
      ridingCount: riding.ridingKeys.length,
      maxBytes: maxBytes,
    ),
  );
  return rewritten;
}

/// The #1916 AC2 fold: every TextContent data-URL payload at or above
/// [embeddedImageMinChars] becomes an [ImageContent] block (text around
/// the URL is kept, split at the URL edges). Returns the original message
/// untouched when nothing folded — the common case pays one
/// `contains('data:image/')` scan per text block.
(Message, bool) _extractEmbeddedImages(Message message) {
  (List<ContentBlock>, bool)? foldBlocks(List<ContentBlock> blocks) {
    var changed = false;
    final out = <ContentBlock>[];
    for (final block in blocks) {
      if (block is! TextContent || !block.text.contains('data:image/')) {
        out.add(block);
        continue;
      }
      final text = block.text;
      var cursor = 0;
      var localChanged = false;
      for (final match in _embeddedImagePattern.allMatches(text)) {
        final payload = match.group(2)!;
        if (payload.length < embeddedImageMinChars) continue;
        final mime = match.group(1)! == 'jpg'
            ? 'image/jpeg'
            : 'image/${match.group(1)!}';
        if (match.start > cursor) {
          out.add(TextContent(text: text.substring(cursor, match.start)));
        }
        out.add(ImageContent(data: payload, mimeType: mime));
        cursor = match.end;
        localChanged = true;
      }
      if (!localChanged) {
        out.add(block);
        continue;
      }
      if (cursor < text.length) {
        out.add(TextContent(text: text.substring(cursor)));
      }
      changed = true;
    }
    return changed ? (out, true) : null;
  }

  switch (message) {
    case UserMessage(:final content, :final timestamp):
      if (content is String) {
        if (!content.contains('data:image/')) return (message, false);
        final folded = foldBlocks([TextContent(text: content)]);
        if (folded == null) return (message, false);
        return (UserMessage(content: folded.$1, timestamp: timestamp), true);
      }
      final folded = foldBlocks(content as List<ContentBlock>);
      return folded == null
          ? (message, false)
          : (UserMessage(content: folded.$1, timestamp: timestamp), true);
    case ToolResultMessage():
      final folded = foldBlocks(message.content);
      return folded == null
          ? (message, false)
          : (
              ToolResultMessage(
                toolCallId: message.toolCallId,
                toolName: message.toolName,
                content: folded.$1,
                isError: message.isError,
                timestamp: message.timestamp,
              ),
              true,
            );
    case AssistantMessage():
      final folded = foldBlocks(message.content);
      return folded == null
          ? (message, false)
          : (message.copyWith(content: folded.$1), true);
    default:
      return (message, false);
  }
}

/// Whether [message] is a projected renumbering boundary: a classic
/// compaction summary, a structured hidden/checkpoint marker, or the
/// local trim valve note. Any of these means history was evicted at some
/// point, so `[Image N]` citations authored before it may now bind to a
/// different image (issue #195 F2).
///
/// THE one predicate (gh-1409): shared with the operative-pin carrier
/// (`../skills/operative_pins.dart`) so both payload rewrites see the
/// same boundary set — the clone gate rejects a second copy.
bool _isRenumberingBoundary(Message message) =>
    isPinRenumberingBoundary(message);

/// Scan pass: first-seen entries + per-key occurrence positions.
void _scanImages(
  List<Message> messages,
  Map<String, ImageRegistryEntry> entryByKey,
  Map<String, List<int>> occurrences,
) {
  for (var i = 0; i < messages.length; i++) {
    for (final image in _imagesOf(messages[i])) {
      final key = imageContentKey(image);
      var entry = entryByKey[key];
      if (entry == null) {
        entry = ImageRegistryEntry(
          index: entryByKey.length,
          key: key,
          data: image.data,
          mimeType: image.mimeType,
        );
        entryByKey[key] = entry;
      }
      occurrences.putIfAbsent(key, () => []).add(i);
    }
  }
}

/// The current user message: the LAST one in the window (I3 — a mid-run
/// steering message is the newest thing the user said).
int _lastUserMessageIndex(List<Message> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i] is UserMessage) return i;
  }
  return -1;
}

/// The riding-set selection result.
final class _RidingSelection {
  const _RidingSelection(
    this.currentKeys,
    this.ridingKeys,
    this.indexByKey,
    this.drops,
    this.currentImageCount,
  );

  /// Keys occurring in the current message (ride in place, up to the cap).
  final Set<String> currentKeys;

  /// Every key riding the request (current + capped history).
  final Set<String> ridingKeys;

  /// `{key → [Image N] index}` for riding keys.
  final Map<String, int> indexByKey;

  /// Every cap drop of the request, current-message drops first.
  final List<ImageDropEvent> drops;

  /// Unique images the current message carried (rode or dropped).
  final int currentImageCount;
}

/// Riding set. The caps apply to the whole request (#1889 R2 + #1916
/// AC1): the current message's images claim slots FIRST — first-seen
/// order within the message — and a batch bigger than the count cap or
/// the byte budget drops its extras as current-message drops (just
/// attached, immediately capped — the actionable case). The remaining
/// slots go to the newest history keys, ties by first-seen order;
/// history overflow drops as history drops. Both limits ride the same
/// greedy pass — whichever binds first names the drop's reason; a
/// byte-drop never stops the scan (a smaller older image still fits).
/// Every drop is reported — never silent. Phases live in the helpers
/// below; this orchestrator only sequences them.
_RidingSelection _selectRiding(
  List<Message> messages,
  Map<String, ImageRegistryEntry> entryByKey,
  Map<String, List<int>> occurrences,
  int currentIdx,
  int cap,
  int maxBytes,
) {
  // Current-message keys in first-seen (document) order, deduped.
  final currentOrdered = _currentKeysInOrder(messages, currentIdx);
  final current = _claimCurrentBatch(currentOrdered, entryByKey, cap, maxBytes);
  final historyKeys = _recencyOrderedHistoryKeys(
    entryByKey,
    occurrences,
    exclude: {...current.ride, ...current.droppedKeys},
  );
  final history = _fillHistorySlots(
    historyKeys,
    entryByKey,
    countSlots: (cap - current.ride.length).clamp(0, historyKeys.length),
    remainingBytes: current.remainingBytes,
    maxBytes: maxBytes,
  );
  final drops = [...current.drops, ...history.drops];
  final ridingKeys = {...current.ride, ...history.ride};
  return _RidingSelection(
    current.ride,
    ridingKeys,
    {for (final key in ridingKeys) key: entryByKey[key]!.index},
    drops,
    currentOrdered.length,
  );
}

/// Which limit overflowed a candidate: the count cap binds first
/// (structural — the reason a byte-drop alone can still ride later),
/// bytes name the drop only when the count allowed it.
ImageDropReason _dropReason({
  required bool overCount,
  required bool overBytes,
}) => overCount ? ImageDropReason.count : ImageDropReason.bytes;

/// The current message's image keys in first-seen (document) order,
/// deduped by content key.
List<String> _currentKeysInOrder(List<Message> messages, int currentIdx) {
  if (currentIdx < 0) return const <String>[];
  final ordered = <String>[];
  final seen = <String>{};
  for (final image in _imagesOf(messages[currentIdx])) {
    final key = imageContentKey(image);
    if (seen.add(key)) ordered.add(key);
  }
  return ordered;
}

/// One batch's claim on the caps: the keys that ride, the drops in
/// encounter order, and the byte budget left for history.
final class _BatchClaim {
  const _BatchClaim(this.ride, this.drops, this.remainingBytes);

  final Set<String> ride;
  final List<ImageDropEvent> drops;
  final int remainingBytes;

  /// Keys this batch dropped — history must never re-claim them.
  Set<String> get droppedKeys => {for (final drop in drops) drop.key};
}

/// The current batch's claim (#1889 R2 + #1916 AC1): slots first-come
/// first-seen; over-count or over-budget images drop as current-message
/// drops (just attached, immediately capped — the actionable case).
_BatchClaim _claimCurrentBatch(
  List<String> ordered,
  Map<String, ImageRegistryEntry> entryByKey,
  int cap,
  int maxBytes,
) {
  final ride = <String>{};
  final drops = <ImageDropEvent>[];
  var remaining = maxBytes;
  for (final key in ordered) {
    final size = entryByKey[key]!.data.length;
    final overCount = ride.length >= cap;
    final overBytes = maxBytes > 0 && size > remaining;
    if (overCount || overBytes) {
      drops.add(
        ImageDropEvent(
          index: entryByKey[key]!.index,
          key: key,
          fromCurrentMessage: true,
          reason: _dropReason(overCount: overCount, overBytes: overBytes),
        ),
      );
      continue;
    }
    ride.add(key);
    if (maxBytes > 0) remaining -= size;
  }
  return _BatchClaim(ride, drops, remaining);
}

/// History keys newest-first (last occurrence recency, ties by
/// first-seen index), minus every key the current batch claimed.
List<String> _recencyOrderedHistoryKeys(
  Map<String, ImageRegistryEntry> entryByKey,
  Map<String, List<int>> occurrences, {
  required Set<String> exclude,
}) {
  int lastSeen(String key) => occurrences[key]!.last;
  final keys = [
    for (final entry in entryByKey.values)
      if (!exclude.contains(entry.key)) entry.key,
  ];
  keys.sort((a, b) {
    final byRecency = lastSeen(b).compareTo(lastSeen(a));
    return byRecency != 0
        ? byRecency
        : entryByKey[a]!.index.compareTo(entryByKey[b]!.index);
  });
  return keys;
}

/// The history fill's outcome: the keys that rode and the drops in
/// scan (newest-first) order.
final class _HistoryFill {
  const _HistoryFill(this.ride, this.drops);
  final Set<String> ride;
  final List<ImageDropEvent> drops;
}

/// The greedy history fill (#1916 AC1): newest-first while count slots
/// and the byte budget hold; a byte drop never stops the scan — a
/// smaller older image still fits. Drop order and reasons are pinned by
/// tests (drop order stays current-first-then-newest).
_HistoryFill _fillHistorySlots(
  List<String> historyKeys,
  Map<String, ImageRegistryEntry> entryByKey, {
  required int countSlots,
  required int remainingBytes,
  required int maxBytes,
}) {
  final ride = <String>{};
  final drops = <ImageDropEvent>[];
  var remaining = remainingBytes;
  for (final key in historyKeys) {
    final entry = entryByKey[key]!;
    final overCount = ride.length >= countSlots;
    final overBytes = maxBytes > 0 && entry.data.length > remaining;
    if (overCount || overBytes) {
      drops.add(
        ImageDropEvent(
          index: entry.index,
          key: entry.key,
          fromCurrentMessage: false,
          reason: _dropReason(overCount: overCount, overBytes: overBytes),
        ),
      );
      continue;
    }
    ride.add(key);
    remaining -= entry.data.length;
  }
  return _HistoryFill(ride, drops);
}

/// The carrier insertion plan: index → carriers before/after that message.
final class _CarrierPlan {
  const _CarrierPlan(this.before, this.after);
  final Map<int, List<UserMessage>> before;
  final Map<int, List<UserMessage>> after;
}

/// One carrier per riding key that never occurs in the current message,
/// anchored at its FIRST occurrence — before the referencing user
/// message, or after the tool-result run that holds it (never inside:
/// nothing may sit between a tool call and its result).
_CarrierPlan _planCarriers(
  List<Message> messages,
  Map<String, ImageRegistryEntry> entryByKey,
  Map<String, List<int>> occurrences,
  _RidingSelection riding,
) {
  final before = <int, List<UserMessage>>{};
  final after = <int, List<UserMessage>>{};
  final ridingByIndex = [...riding.ridingKeys]
    ..sort((a, b) => entryByKey[a]!.index.compareTo(entryByKey[b]!.index));
  for (final key in ridingByIndex) {
    if (riding.currentKeys.contains(key)) continue;
    final entry = entryByKey[key]!;
    final firstIdx = occurrences[key]!.first;
    final carrier = UserMessage(
      content: [
        TextContent(text: imageRefLabel(entry.index)),
        ImageContent(data: entry.data, mimeType: entry.mimeType),
      ],
      timestamp: messages[firstIdx].timestamp,
    );
    if (messages[firstIdx] is UserMessage) {
      before.putIfAbsent(firstIdx, () => []).add(carrier);
    } else {
      var runEnd = firstIdx;
      while (runEnd + 1 < messages.length &&
          messages[runEnd + 1] is ToolResultMessage) {
        runEnd++;
      }
      after.putIfAbsent(runEnd, () => []).add(carrier);
    }
  }
  return _CarrierPlan(before, after);
}

/// Emit pass: rewritten history (image blocks → refs/notes), the current
/// message with its RIDING images in place (over-cap extras → the note),
/// carriers at their anchors.
List<Message> _emitRewritten(
  List<Message> messages,
  int currentIdx,
  _RidingSelection riding,
  _CarrierPlan carriers,
) {
  final out = <Message>[];
  for (var i = 0; i < messages.length; i++) {
    out.addAll(carriers.before[i] ?? const <Message>[]);
    final message = messages[i];
    if (i == currentIdx) {
      out.add(
        _labelCurrentImages(message, riding.indexByKey, riding.ridingKeys),
      );
    } else if (message is UserMessage) {
      final content = message.content;
      out.add(
        content is List<ContentBlock>
            ? _rewriteUserBlocks(message, content, riding.indexByKey)
            : message,
      );
    } else if (message is ToolResultMessage) {
      out.add(_rewriteResultBlocks(message, riding.indexByKey));
    } else {
      out.add(message);
    }
    out.addAll(carriers.after[i] ?? const <Message>[]);
  }
  return out;
}

/// F3: the current message's RIDING images stay in place AND carry their
/// `[Image N]` label as a preceding text block — the model can cite the
/// image it is looking at with the number the registry will honor.
/// Over-cap current images (issue #1889 R2) resolve to the unavailable
/// note, exactly like dropped history occurrences.
Message _labelCurrentImages(
  Message message,
  Map<String, int> indexByKey,
  Set<String> ridingKeys,
) {
  if (message is! UserMessage) return message;
  final content = message.content;
  if (content is! List<ContentBlock>) return message;
  if (!content.any((block) => block is ImageContent)) return message;
  return UserMessage(
    content: [
      for (final block in content)
        if (block is ImageContent &&
            ridingKeys.contains(imageContentKey(block))) ...[
          TextContent(
            text: imageRefLabel(indexByKey[imageContentKey(block)] ?? 0),
          ),
          block,
        ] else if (block is ImageContent)
          TextContent(text: unavailableImageNote)
        else
          block,
    ],
    timestamp: message.timestamp,
  );
}

Iterable<ImageContent> _imagesOf(Message message) sync* {
  if (message is UserMessage) {
    final content = message.content;
    if (content is List<ContentBlock>) {
      yield* content.whereType<ImageContent>();
    }
  } else if (message is ToolResultMessage) {
    yield* message.content.whereType<ImageContent>();
  }
}

/// Whether any citable text surface of [message] carries a `[Image N]`
/// mention (fast-path guard — a miss here would leave a dangling ref).
bool _mentionsImageRef(Message message) {
  final texts = <String>[];
  switch (message) {
    case UserMessage(:final content):
      if (content is String) texts.add(content);
      if (content is List<ContentBlock>) {
        texts.addAll([
          for (final block in content)
            if (block is TextContent) block.text,
        ]);
      }
    case AssistantMessage(:final content):
      texts.addAll([
        for (final block in content)
          if (block is TextContent) block.text,
      ]);
    case ToolResultMessage(:final content):
      texts.addAll([
        for (final block in content)
          if (block is TextContent) block.text,
      ]);
  }
  return texts.any((text) => text.contains('[Image '));
}

UserMessage _rewriteUserBlocks(
  UserMessage message,
  List<ContentBlock> content,
  Map<String, int> ridingIndexByKey,
) {
  if (!content.any((block) => block is ImageContent)) return message;
  return UserMessage(
    content: _replaceImageBlocks(content, ridingIndexByKey),
    timestamp: message.timestamp,
  );
}

ToolResultMessage _rewriteResultBlocks(
  ToolResultMessage message,
  Map<String, int> ridingIndexByKey,
) {
  if (!message.content.any((block) => block is ImageContent)) return message;
  return ToolResultMessage(
    toolCallId: message.toolCallId,
    toolName: message.toolName,
    content: _replaceImageBlocks(message.content, ridingIndexByKey),
    isError: message.isError,
    timestamp: message.timestamp,
  );
}

/// Swaps image blocks for refs (riding) or the unavailable note (dropped).
List<ContentBlock> _replaceImageBlocks(
  List<ContentBlock> content,
  Map<String, int> ridingIndexByKey,
) {
  return [
    for (final block in content)
      switch (block) {
        ImageContent() => switch (ridingIndexByKey[imageContentKey(block)]) {
          final index? => TextContent(text: imageRefLabel(index)),
          null => const TextContent(text: unavailableImageNote),
        },
        _ => block,
      },
  ];
}

/// Resolves `[Image N]` text mentions against the riding set (I4).
///
/// When [trusted] is false (history authored before a renumbering
/// boundary — issue #195 F2), every mention degrades to the note: the
/// number may name a different image now, and a silent rebind would feed
/// the model wrong data.
Message _resolveMentions(
  Message message,
  Set<int> ridingIndexes, {
  bool trusted = true,
}) {
  String fix(String text) => text.contains('[Image ')
      ? text.replaceAllMapped(
          imageRefPattern,
          (match) =>
              trusted && ridingIndexes.contains(int.parse(match.group(1)!))
              ? match.group(0)!
              : unavailableImageNote,
        )
      : text;

  (List<ContentBlock>, bool) fixBlocks(List<ContentBlock> blocks) {
    var changed = false;
    return (
      [
        for (final block in blocks)
          switch (block) {
            TextContent(:final text) when text.contains('[Image ') => () {
              final fixed = fix(text);
              changed = changed || fixed != text;
              return block.copyWith(text: fixed);
            }(),
            _ => block,
          },
      ],
      changed,
    );
  }

  switch (message) {
    case UserMessage(:final content, :final timestamp):
      if (content is String) {
        final fixed = fix(content);
        return fixed == content
            ? message
            : UserMessage(content: fixed, timestamp: timestamp);
      }
      final (blocks, changed) = fixBlocks(content as List<ContentBlock>);
      return changed
          ? UserMessage(content: blocks, timestamp: timestamp)
          : message;
    case ToolResultMessage():
      final (blocks, changed) = fixBlocks(message.content);
      return changed
          ? ToolResultMessage(
              toolCallId: message.toolCallId,
              toolName: message.toolName,
              content: blocks,
              isError: message.isError,
              timestamp: message.timestamp,
            )
          : message;
    case AssistantMessage():
      final (blocks, changed) = fixBlocks(message.content);
      return changed ? message.copyWith(content: blocks) : message;
    default:
      return message;
  }
}
