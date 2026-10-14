/// The pure ForeignRecord → FA append-plan mapper (issue #1562, GOAL
/// M-section): no IO, no session, no repository — a [ForeignParseResult]
/// in, a [MappedImport] (planned appends + counts) out. The runner
/// ([runImport]) executes the plans through `Session.append*` only.
library;

import '../context.dart';
import '../types.dart';
import 'foreign_session.dart';

/// One planned append: the mapper's verdict for a foreign record.
sealed class PlannedRecord {
  const PlannedRecord();
}

/// `Session.appendSessionName` — the newest-wins, user-preferred title
/// (newline sanitization is FA's own, GOAL F5).
final class PlannedName extends PlannedRecord {
  const PlannedName(this.name);
  final String name;
}

/// `Session.appendMessage`.
final class PlannedMessage extends PlannedRecord {
  const PlannedMessage(this.message);
  final Message message;
}

/// `Session.appendModelChange`.
final class PlannedModelChange extends PlannedRecord {
  const PlannedModelChange({required this.provider, required this.modelId});
  final String provider;
  final String modelId;
}

/// `Session.appendThinkingLevelChange`.
final class PlannedThinkingLevel extends PlannedRecord {
  const PlannedThinkingLevel(this.level);
  final String level;
}

/// `Session.appendCompaction` — summary verbatim; the foreign optional
/// fields are counted in [droppedFields] (they reference foreign record
/// ids that cannot resolve inside the FA file).
final class PlannedCompaction extends PlannedRecord {
  const PlannedCompaction(this.summary, this.droppedFields);
  final String summary;
  final List<String> droppedFields;
}

/// `Session.appendCustomEntry` — inert data, never re-activated.
final class PlannedCustom extends PlannedRecord {
  const PlannedCustom(this.customType, this.data);
  final String customType;
  final Object? data;
}

/// `Session.appendCustomMessageEntry`.
final class PlannedCustomMessage extends PlannedRecord {
  const PlannedCustomMessage({
    required this.customType,
    required this.content,
    required this.display,
    this.details,
  });
  final String customType;
  final Object content;
  final bool display;
  final Object? details;
}

/// One mapped record: the source (for counts) and its plan.
final class MappedItem {
  const MappedItem({required this.source, required this.planned});
  final ForeignRecord source;
  final PlannedRecord planned;
}

/// The mapper output for one foreign session.
final class MappedImport {
  const MappedImport({
    required this.items,
    required this.skippedRecords,
    required this.skippedBlocks,
    required this.droppedFields,
  });

  /// Planned appends in leaf-path order (a leading [PlannedName] when a
  /// title or fallback name exists).
  final List<MappedItem> items;

  /// Whole foreign records dropped (unparseable lines, off-branch,
  /// sidechains) — the summary's `skipped <n>`.
  final int skippedRecords;

  /// Content blocks placeholder-ed inside mapped records.
  final int skippedBlocks;

  /// Field-level drops per field name (mapping-table pins, GOAL M-section).
  final Map<String, int> droppedFields;
}

/// Maps one parsed foreign session to FA append plans.
///
/// [harness] namespaces the inert custom entries (`import.<harness>` with
/// the foreign customType carried byte-exact inside `data`).
MappedImport mapForeignSession(ForeignParseResult parse, String harness) {
  final prefix = 'import.$harness';
  final items = <MappedItem>[];
  final skippedRecords = parse.skippedRecords;
  final droppedFields = <String, int>{};
  void dropField(String field) =>
      droppedFields[field] = (droppedFields[field] ?? 0) + 1;

  var title = '';
  var titleSource = '';
  String? fallbackName;
  final toolCallIds = <String>{};

  void updateTitle(String newTitle, String newSource) {
    if (newTitle.isEmpty) return;
    if (title.isNotEmpty && titleSource == 'user' && newSource != 'user') {
      return; // user titles beat auto titles regardless of order
    }
    title = newTitle;
    titleSource = newSource;
  }

  for (final record in parse.records) {
    switch (record) {
      case ForeignTitleSlot(:final title, :final source):
        updateTitle(title, source);
      case ForeignHeader():
        break; // identity only — FA writes its own header
      case ForeignMessage():
        final planned = _mapMessage(
          record,
          prefix,
          toolCallIds,
          dropField,
          (name) => fallbackName ??= name,
        );
        if (planned != null) {
          items.add(MappedItem(source: record, planned: planned));
        }
      case ForeignModelChange(:final model):
        final split = model.indexOf('/');
        items.add(
          MappedItem(
            source: record,
            planned: PlannedModelChange(
              provider: split > 0 ? model.substring(0, split) : 'omp',
              modelId: model,
            ),
          ),
        );
      case ForeignThinkingLevelChange(:final level):
        items.add(
          MappedItem(source: record, planned: PlannedThinkingLevel(level)),
        );
      case ForeignCompaction(:final summary, :final droppedFields):
        for (final field in droppedFields) {
          dropField(field);
        }
        items.add(
          MappedItem(
            source: record,
            planned: PlannedCompaction(summary, droppedFields),
          ),
        );
      case ForeignCustom(:final customType, :final data):
        items.add(
          MappedItem(
            source: record,
            planned: PlannedCustom(prefix, {
              'customType': customType,
              'data': data,
            }),
          ),
        );
      case ForeignCustomMessage(
        :final customType,
        :final content,
        :final display,
        :final details,
        :final attribution,
      ):
        items.add(
          MappedItem(
            source: record,
            planned: PlannedCustomMessage(
              customType: prefix,
              content: content,
              display: display,
              details: {
                'customType': customType,
                'attribution': ?attribution,
                'details': ?details,
              },
            ),
          ),
        );
      case ForeignUnhandled(:final type, :final raw):
        items.add(
          MappedItem(
            source: record,
            planned: PlannedCustom('$prefix.${_safeType(type)}', raw),
          ),
        );
    }
  }

  final name = (title.isNotEmpty ? title : fallbackName ?? '').trim();
  if (name.isNotEmpty && parse.records.isNotEmpty) {
    items.insert(
      0,
      MappedItem(source: parse.records.first, planned: PlannedName(name)),
    );
  }
  return MappedImport(
    items: items,
    skippedRecords: skippedRecords,
    skippedBlocks: parse.skippedBlocks,
    droppedFields: droppedFields,
  );
}

/// Custom-entry type suffixes are built from foreign type strings; keep
/// the FA customType a single line.
String _safeType(String type) => type.replaceAll(RegExp(r'[\r\n]+'), ' ');

/// Message-role mapping (GOAL M-section rows).
PlannedRecord? _mapMessage(
  ForeignMessage record,
  String prefix,
  Set<String> toolCallIds,
  void Function(String) dropField,
  void Function(String) captureFallbackName,
) {
  switch (record.role) {
    case 'user':
    case 'developer':
      final message = _userMessage(
        record,
        (name) => captureFallbackName(_namePrefix(name)),
      );
      return PlannedMessage(message);
    case 'assistant':
      return PlannedMessage(_assistantMessage(record, toolCallIds, dropField));
    case 'toolResult':
      final callId = record.toolCallId ?? '';
      if (!toolCallIds.contains(callId)) {
        // Orphan tool result (GOAL O4 negative): a counted custom entry,
        // never dropped silently and never a broken FA message.
        return PlannedCustom('$prefix.orphanToolResult', record.rawMessage);
      }
      return PlannedMessage(
        ToolResultMessage(
          toolCallId: callId,
          toolName: record.toolName ?? '',
          content: _faBlocks(record.contents),
          isError: record.isError,
          timestamp: _epoch,
        ),
      );
    default:
      // bashExecution / pythonExecution / fileMention / hookMessage and
      // any future role: faithful-as-data, no execution semantics.
      return PlannedCustom(
        '$prefix.${_safeType(record.role)}',
        record.rawMessage,
      );
  }
}

/// Mapper-fixed timestamp for mapped messages: provenance timestamps ride
/// the session file order; FA records stamp append time.
final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

/// The unnamed-session fallback name (GOAL F5 pin): the first user message
/// text, capped.
String _namePrefix(String text) {
  final flat = text.replaceAll('\n', ' ').trim();
  return flat.length > 80 ? '${flat.substring(0, 80)}…' : flat;
}

UserMessage _userMessage(
  ForeignMessage record,
  void Function(String) captureFallbackName,
) {
  final text = foreignContentText(record.contents);
  if (text.isNotEmpty) captureFallbackName(text);
  final blocks = _faBlocks(record.contents);
  final content = blocks.length == 1 && blocks.single is TextContent
      ? (blocks.single as TextContent).text
      : blocks;
  return UserMessage(content: content, timestamp: _epoch);
}

AssistantMessage _assistantMessage(
  ForeignMessage record,
  Set<String> toolCallIds,
  void Function(String) dropField,
) {
  final blocks = <ContentBlock>[];
  for (final content in record.contents) {
    switch (content) {
      case ForeignText(:final text):
        blocks.add(TextContent(text: text));
      case ForeignThinking(:final thinking, :final signature):
        blocks.add(
          ThinkingContent(thinking: thinking, thinkingSignature: signature),
        );
      case ForeignToolCall(
        :final id,
        :final name,
        :final arguments,
        :final partialArguments,
      ):
        toolCallIds.add(id);
        blocks.add(
          ToolCall(
            id: id,
            name: name,
            arguments: arguments,
            partialArguments: partialArguments,
          ),
        );
      case ForeignImage(
        :final base64Data,
        :final mimeType,
        :final missingReason,
      ):
        if (base64Data != null) {
          blocks.add(
            ImageContent(data: base64Data, mimeType: mimeType ?? 'image/png'),
          );
        } else {
          blocks.add(
            TextContent(
              text: '[image skipped: ${missingReason ?? 'unavailable'}]',
            ),
          );
        }
      case ForeignUnknownBlock():
        dropField('content-block');
    }
  }
  final usage = _mapUsage(record.usage, dropField);
  return AssistantMessage(
    content: blocks,
    api: record.api ?? '',
    provider: record.provider ?? '',
    model: record.model ?? '',
    usage: usage,
    stopReason: _mapStopReason(record.stopReason),
    rawStopReason: record.stopReason,
    errorMessage: record.errorMessage,
    timestamp: _epoch,
  );
}

/// Builds FA content blocks for user/toolResult payloads: text and images
/// carry, everything else becomes a counted inline placeholder.
List<ContentBlock> _faBlocks(List<ForeignContent> contents) {
  final blocks = <ContentBlock>[];
  for (final content in contents) {
    switch (content) {
      case ForeignText(:final text):
        blocks.add(TextContent(text: text));
      case ForeignImage(
        :final base64Data,
        :final mimeType,
        :final missingReason,
      ):
        if (base64Data != null) {
          blocks.add(
            ImageContent(data: base64Data, mimeType: mimeType ?? 'image/png'),
          );
        } else {
          blocks.add(
            TextContent(
              text: '[image skipped: ${missingReason ?? 'unavailable'}]',
            ),
          );
        }
      case ForeignThinking(:final thinking):
        blocks.add(TextContent(text: thinking));
      case ForeignToolCall():
        blocks.add(const TextContent(text: '[tool call]'));
      case ForeignUnknownBlock():
        blocks.add(const TextContent(text: '[unmapped content]'));
    }
  }
  if (blocks.isEmpty) blocks.add(TextContent(text: ''));
  return blocks;
}

/// Maps the foreign usage map onto FA [Usage] best-effort; keys outside
/// FA's usage shape count as dropped fields (mapping-table pin).
Usage _mapUsage(Map<String, dynamic>? usage, void Function(String) dropField) {
  if (usage == null) return Usage.zero;
  int token(String key) {
    final value = usage[key];
    if (value == null) return 0;
    if (value is num) return value.toInt();
    dropField('usage.$key');
    return 0;
  }

  final cost = usage['cost'];
  if (usage['cost'] != null && cost is! Map<String, dynamic>) {
    dropField('usage.cost');
  }
  final mappedUsage = Usage(
    input: token('input'),
    output: token('output'),
    cacheRead: token('cacheRead'),
    cacheWrite: token('cacheWrite'),
    reasoning: usage['reasoning'] is num
        ? (usage['reasoning'] as num).toInt()
        : null,
    totalTokens: usage['totalTokens'] == null
        ? token('input') + token('output')
        : token('totalTokens'),
    cost: cost is Map<String, dynamic>
        ? UsageCost.fromJson(cost)
        : const UsageCost(),
  );
  const mappedKeys = {
    'input',
    'output',
    'cacheRead',
    'cacheWrite',
    'totalTokens',
    'cost',
    'reasoning',
  };
  for (final key in usage.keys) {
    if (!mappedKeys.contains(key) && usage[key] != null) {
      dropField('usage.$key');
    }
  }
  return mappedUsage;
}

/// Foreign stop reasons are pi-family names (`stop`, `length`, `toolUse`,
/// `error`, `aborted`); unknown strings degrade to [StopReason.stop] with
/// the raw value kept in `rawStopReason`.
StopReason _mapStopReason(String? raw) => switch (raw) {
  'stop' => StopReason.stop,
  'length' => StopReason.length,
  'toolUse' => StopReason.toolUse,
  'error' => StopReason.error,
  'aborted' => StopReason.aborted,
  _ => StopReason.stop,
};
