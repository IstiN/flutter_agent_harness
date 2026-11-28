/// The `record_tag` wire protocol (GOAL #2394, Compaction 2.0 v2.1).
///
/// Every visible session record rides the wire prefixed with its file
/// alias — `m<seq> ` (`m142 toolResult(bash): …`) — so the model can
/// ADDRESS records in a hand-over reply ("hide 142-143") and the engine
/// can resolve those numbers back to stable record ids through the
/// SNAPSHOT index of the request the model actually saw.
///
/// Invariants (I4):
/// - a tag is wire-only: it is stamped on a COPY of the transcript right
///   before the request transforms, never on the transcript itself, never
///   persisted (`Context.toJson` is untouched);
/// - inside a tag epoch (the projection the transcript was rebuilt from)
///   the head messages carry their exact alias and the bytes are stable;
///   messages appended after the epoch started (the run's live edge —
///   the prompt, nudges, this run's answers and tool results) carry NO
///   tag: they are not records of this epoch yet (persistence is
///   asynchronous) and the model does not address them. The next epoch
///   (the next run's projection rebuild) tags them — one uncached
///   segment at the run boundary (E30), visible in the main request's
///   cache metric and the accepted conservative default of the card;
/// - non-records (the obligations / working-set tail blocks, `time-left:`
///   lines, carrier pins, the hand-over instruction) never carry a tag;
/// - tags exist only under the structured engine (`compaction.engine`).
///
/// Pure Dart — no IO; the transcript seq map is built by the session
/// projection (`Session.buildTranscriptProjection`).
library;

import '../context.dart';
import '../types.dart';
import 'structured/projection.dart' show RecordSeqIndex;

/// The pressure-basis cost of one record tag: `m142 ` is 2 tiktoken
/// tokens (o200k) and ≤ 5 for six-digit aliases — the budget pinned for
/// the `tagOverhead` term of the request estimate (D14).
const int recordTagTokens = 5;

/// The maximum alias the 5-token budget covers (`m999999 `).
const int _recordTagMaxSeq = 999999;

final RegExp _recordTagLineStart = RegExp(r'^m(\d+) ');
final RegExp _recordTagEchoLines = RegExp(r'^m\d+ +', multiLine: true);

/// The wire form of record [seq]: `m<seq>`.
String recordTag(int seq) => 'm$seq';

/// The seq a [text] opens with (`m142 rest` → 142), else `null`.
int? leadingRecordTag(String text) {
  final match = _recordTagLineStart.firstMatch(text);
  if (match == null) return null;
  final seq = int.tryParse(match.group(1)!);
  return seq != null && seq > 0 && seq <= _recordTagMaxSeq ? seq : null;
}

/// Whether [text] opens with a record tag (a tagged record line).
bool hasRecordTag(String text) => leadingRecordTag(text) != null;

/// Whether [message] is a record copy whose first text block opens with a
/// tag (the stamping is idempotent: a tagged copy is returned as is).
bool messageHasRecordTag(Message message) =>
    leadingRecordTag(firstTextOf(message)) != null;

/// The text of [message]'s first text block ('' when it has none).
String firstTextOf(Message message) {
  final blocks = messageBlocks(message);
  for (final block in blocks) {
    if (block is TextContent) return block.text;
  }
  return '';
}

/// The content blocks of [message] (a plain-string user message is a
/// one-text-block list; unknown shapes fold to empty).
List<ContentBlock> messageBlocks(Message message) => switch (message) {
  UserMessage(:final content) when content is List => [
    for (final block in content) block,
  ],
  UserMessage(:final content) => [TextContent(text: content as String)],
  ToolResultMessage(:final content) => content,
  AssistantMessage(:final content) => content,
  _ => const [],
};

/// Removes every leading `m<N> ` tag from the start of [text]'s lines —
/// the persist-side echo hygiene (E16): a hand-over text that repeated
/// the wire tags carries none once stored.
String stripRecordTags(String text) => text.replaceAll(_recordTagEchoLines, '');

/// Streaming-safe echo hygiene for user-facing render paths (gh-2472).
///
/// [stripRecordTags] works on COMPLETE texts; a live delta stream must not
/// show the tag's own bytes even transiently — a prefix split across
/// deltas (`m14` then `82 При…`) would flicker `m14` onto the screen
/// before the tag completed. This filter classifies each LINE START
/// before any of its bytes are emitted: it holds only the undecided `m`
/// + digits prefix, swallows it (plus the tag's trailing spaces — across
/// delta boundaries too) when a space confirms the tag, and releases the
/// bytes verbatim the moment they cannot be a tag. A line start re-arms
/// the classification, so every line of a multi-line reply is judged
/// independently — the same semantics as [stripRecordTags]'s `^m\d+ +`
/// (the gh-2412 contract; a tab is not a tag terminator, `m3u8 ` is not
/// an alias). [flush] emits an undecided tail verbatim — a text ending
/// `m2` with no trailing space never matched the rule, so the bytes are
/// the model's own words — and resets, so the next message classifies
/// from a fresh line.
enum _TagScan {
  /// At a line start: the next byte decides between a candidate alias and
  /// ordinary text.
  lineStart,

  /// Inside a `m<digits> ` candidate — bytes held in [_aliasBuffer].
  alias,

  /// Tag confirmed: swallowing the rule's trailing ` +` run.
  spaces,

  /// Past the line start: pass-through until the next newline.
  text,
}

final class RecordTagEchoStreamFilter {
  _TagScan _scan = _TagScan.lineStart;

  /// The undecided `m` + digits prefix of the current line.
  final StringBuffer _aliasBuffer = StringBuffer();

  /// Streams one delta; returns the text safe to render now (possibly
  /// empty — bytes held back while a line start is still undecided).
  String push(String delta) {
    final out = StringBuffer();
    for (final ch in delta.codeUnits) {
      switch (_scan) {
        case _TagScan.lineStart when ch == 0x6D /* m */ :
          _scan = _TagScan.alias;
          _aliasBuffer
            ..clear()
            ..writeCharCode(ch);
        case _TagScan.lineStart:
          out.writeCharCode(ch);
          _scan = ch == 0x0A /* \n */ ? _TagScan.lineStart : _TagScan.text;
        case _TagScan.alias when _isDigit(ch):
          _aliasBuffer.writeCharCode(ch);
        case _TagScan.alias when ch == 0x20 /* space */ :
          _scan = _TagScan.spaces;
        case _TagScan.alias:
          // Not a tag (`m3u8`, `m42x`, a bare `m` line): release the
          // held bytes and continue as text.
          out.write(_aliasBuffer.toString());
          out.writeCharCode(ch);
          _scan = ch == 0x0A ? _TagScan.lineStart : _TagScan.text;
        case _TagScan.spaces when ch == 0x20:
          break; // the rule strips the whole ` +` run
        case _TagScan.spaces:
          out.writeCharCode(ch);
          _scan = ch == 0x0A ? _TagScan.lineStart : _TagScan.text;
        case _TagScan.text:
          out.writeCharCode(ch);
          if (ch == 0x0A) _scan = _TagScan.lineStart;
      }
    }
    return out.toString();
  }

  /// End of the message: emits whatever stayed undecided verbatim and
  /// resets the filter for the next message.
  String flush() {
    final held = _scan == _TagScan.alias ? _aliasBuffer.toString() : '';
    _scan = _TagScan.lineStart;
    _aliasBuffer.clear();
    return held;
  }
}

/// Whether the code unit is an ASCII digit (a tag alias is `m<digits>`).
bool _isDigit(int ch) => ch >= 0x30 && ch <= 0x39;

/// One transcript build: the projected messages plus the record alias each
/// message projects from (aligned by index, `null` = a non-record) and
/// the file-order index the aliases resolve against — the tag epoch the
/// agent stamps requests from.
final class TranscriptProjection {
  /// Creates the projection; [recordSeqs] runs parallel to [messages].
  const TranscriptProjection({
    required this.messages,
    required this.recordSeqs,
    required this.index,
  });

  /// The projected transcript (`buildContextMessages` output).
  final List<Message> messages;

  /// The record alias per message, aligned by index (`null` = non-record).
  final List<int?> recordSeqs;

  /// The file-order record index the aliases resolve against.
  final RecordSeqIndex index;

  /// The tag epoch over this projection.
  TranscriptSeqMap get seqMap =>
      TranscriptSeqMap(headSeqs: recordSeqs, index: index);
}

/// The aligned record aliases of a transcript plus the epoch index they
/// resolve against — `null` marks a non-record (level-0 tail blocks,
/// instructions, notices) AND the live edge (messages appended since the
/// epoch started: untaged until the next epoch).
final class TranscriptSeqMap {
  /// Creates the map of one tag epoch: [headSeqs] aligned to the
  /// projected transcript head, [index] the epoch's file-order snapshot.
  const TranscriptSeqMap({required this.headSeqs, required this.index});

  /// The seqs of the projected head, aligned by message index (`null` =
  /// a non-record). Treated as read-only by every consumer.
  final List<int?> headSeqs;

  /// The epoch's record index (seq → record). Frozen at epoch start: an
  /// id beyond it never resolves, so a mis-predicted live-edge alias
  /// cannot hide someone else's record.
  final RecordSeqIndex index;

  /// Number of head messages (the projected transcript at epoch start).
  int get headLength => headSeqs.length;

  /// The alias of the message at [position]: exact on the head (the
  /// epoch's records), `null` beyond it — the live edge carries no tag
  /// (the epoch rule: a message becomes addressable when the NEXT epoch's
  /// projection makes it a record) — and `null` for a non-record.
  int? seqAt(int position) {
    if (position < 0 || position >= headSeqs.length) return null;
    return headSeqs[position];
  }

  /// The stable record id the alias at [position] resolves to on the
  /// epoch index — `null` for non-records, the live edge and unknown
  /// aliases.
  String? recordIdAt(int position) {
    final seq = seqAt(position);
    if (seq == null) return null;
    final record = index.recordAt(seq);
    return record?.id;
  }

  /// The seqs of a [length]-message transcript, aligned by index.
  List<int?> seqsFor(int length) => [for (var i = 0; i < length; i++) seqAt(i)];
}

/// The tag budget of [taggedRecords] tagged messages (the `tagOverhead`
/// term of the request estimate).
int tagOverheadTokens(int taggedRecords) =>
    taggedRecords <= 0 ? 0 : taggedRecords * recordTagTokens;

/// How many messages in [seqs] are tagged records — all of them without a
/// usage anchor, only the ones AFTER the anchor with one (the anchor's
/// reported usage already priced the tags of everything up to it).
int taggedRecordCount(List<int?> seqs, {int? after}) {
  var count = 0;
  for (var i = 0; i < seqs.length; i++) {
    if (seqs[i] != null && (after == null || i > after)) count++;
  }
  return count;
}

/// Stamps record tags on a COPY of [messages]: every message whose aligned
/// seq is non-null gets `m<seq> ` in its first text block; non-records and
/// a `null` map pass through UNTOUCHED (the untagged transcript, the same
/// list). The transcript itself is never modified (I4).
List<Message> tagTranscript(List<Message> messages, TranscriptSeqMap? seqMap) {
  if (seqMap == null || messages.isEmpty) return messages;
  final tagged = <Message>[];
  var changed = false;
  for (var i = 0; i < messages.length; i++) {
    final seq = seqMap.seqAt(i);
    final message = messages[i];
    if (seq == null || messageHasRecordTag(message)) {
      tagged.add(message);
      continue;
    }
    final copy = tagRecordMessage(message, seq);
    changed = true;
    tagged.add(copy);
  }
  return changed ? tagged : messages;
}

/// [tagTranscript] over a request [Context]: the system prompt and tools
/// ride byte-identically, only the message copies carry tags.
Context tagContext(Context context, TranscriptSeqMap? seqMap) {
  if (seqMap == null) return context;
  final tagged = tagTranscript(context.messages, seqMap);
  if (identical(tagged, context.messages)) return context;
  return Context(
    systemPrompt: context.systemPrompt,
    messages: tagged,
    tools: context.tools,
  );
}

/// The tagged copy of one record [message]: the tag goes into the first
/// text block — for an assistant message, the first text block AFTER its
/// leading thinking blocks (signed thinking keeps its position and
/// order; the tag never lands before it). A record with no text block
/// (a pure tool-call carrier, an image-only record) gets a new first
/// text block holding the tag alone (plus `image/<mime>` for images) —
/// image parts are never touched (E17, E18).
Message tagRecordMessage(Message message, int seq) {
  final tag = recordTag(seq);
  switch (message) {
    case UserMessage(:final content, :final timestamp):
      if (content is String) {
        return UserMessage(
          content: _tagText(content, tag),
          timestamp: timestamp,
        );
      }
      return UserMessage(
        content: _tagBlocks(content as List<ContentBlock>, tag),
        timestamp: timestamp,
      );
    case ToolResultMessage(
      :final toolCallId,
      :final toolName,
      :final content,
      :final isError,
      :final timestamp,
    ):
      return ToolResultMessage(
        toolCallId: toolCallId,
        toolName: toolName,
        content: _tagBlocks(content, tag),
        isError: isError,
        timestamp: timestamp,
      );
    case AssistantMessage(:final content):
      return message.copyWith(content: _tagAssistantBlocks(content, tag));
    default:
      return message;
  }
}

String _tagText(String text, String tag) =>
    hasRecordTag(text) ? text : '$tag $text';

String _tagBlocksText(String text, String tag) => '$tag $text';

List<ContentBlock> _tagBlocks(List<ContentBlock> blocks, String tag) {
  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    if (block is TextContent) {
      if (hasRecordTag(block.text)) return blocks;
      return [
        for (var j = 0; j < blocks.length; j++)
          if (j == i)
            block.copyWith(text: _tagBlocksText(block.text, tag))
          else
            blocks[j],
      ];
    }
  }
  // No text block: a tag-only block in front (image parts untouched).
  final image = blocks.whereType<ImageContent>().firstOrNull;
  final label = image == null ? tag : '$tag image/${image.mimeType}';
  return [TextContent(text: label), ...blocks];
}

List<ContentBlock> _tagAssistantBlocks(List<ContentBlock> blocks, String tag) {
  var index = 0;
  while (index < blocks.length && blocks[index] is ThinkingContent) {
    index++;
  }
  for (var i = index; i < blocks.length; i++) {
    final block = blocks[i];
    if (block is TextContent) {
      if (hasRecordTag(block.text)) return blocks;
      return [
        for (var j = 0; j < blocks.length; j++)
          if (j == i)
            block.copyWith(text: _tagBlocksText(block.text, tag))
          else
            blocks[j],
      ];
    }
  }
  // Pure tool-call carrier: a tag-only text block after the thinking
  // blocks (never before signed thinking).
  return [...blocks.take(index), TextContent(text: tag), ...blocks.skip(index)];
}
