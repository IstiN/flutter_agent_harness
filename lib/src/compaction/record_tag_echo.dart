// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

/// gh-2412: record-tag ECHO hygiene for assistant output.
///
/// Record tags are stamped on the WIRE COPY of the transcript only
/// (`tagContext`); the stored records never carry them. A model that
/// repeats its own alias (`m3212 Ответил владельцу с телефона: …`) must
/// not have that echo stored as its words: the alias would render in the
/// TUI as part of the reply, and `messageHasRecordTag` would take the
/// stored turn for an already-stamped copy, so the next epoch skipped
/// stamping it.
///
/// [stripRecordTagEcho] runs at the assistant finalize seam — BEFORE the
/// reply joins the transcript (the agent state and every listener, the
/// session persist included) — and only while record tags are enabled:
/// with tags off a legitimate `m42 ` opening is the model's own text and
/// survives untouched.
library;

import '../types.dart';
import 'record_tag.dart';

/// A reply whose FIRST text block opens with an alias that ends there —
/// `m3208` is a reply that is ONLY its tag ([stripRecordTags] needs the
/// trailing space of a tagged line). The lookahead keeps a legitimate
/// `m3u8 stream` opening intact.
final RegExp _leadingAlias = RegExp(r'^m\d+(?=\s|$)');

/// Removes the record-tag echo from the TEXT blocks of [message]: the
/// leading `m<N>` of the first text block and every `m<N> ` at a line
/// start ([stripRecordTags]). A text block left empty is dropped; tool
/// calls and thinking blocks are never touched. Returns [message] itself
/// when nothing changes.
AssistantMessage stripRecordTagEcho(AssistantMessage message) {
  final cleaned = _stripTextBlocks(message.content);
  return cleaned == null ? message : message.copyWith(content: cleaned);
}

/// [blocks] with every text block cleaned, or `null` when none changed.
List<ContentBlock>? _stripTextBlocks(List<ContentBlock> blocks) {
  final cleaned = <ContentBlock>[];
  var firstText = true;
  var changed = false;
  for (final block in blocks) {
    if (block is! TextContent) {
      cleaned.add(block);
      continue;
    }
    var text = stripRecordTags(block.text);
    if (firstText) {
      final withoutAlias = text.replaceFirst(_leadingAlias, '');
      text = withoutAlias == text ? text : withoutAlias.trimLeft();
    }
    firstText = false;
    changed = changed || text != block.text;
    if (text == block.text) {
      cleaned.add(block);
    } else if (text.trim().isNotEmpty) {
      cleaned.add(block.copyWith(text: text));
    }
  }
  return changed ? cleaned : null;
}
