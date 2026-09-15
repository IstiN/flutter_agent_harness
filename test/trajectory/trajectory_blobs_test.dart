// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the issue-385 blob machinery: content-addressed prompt
/// and manifest blobs (F1/F2), the unified prompt diff (AC2), the
/// tool-set diff (AC3), the message-block structure (F3/AC4), the opt-in
/// wire dump pipeline (F5/AC6), and the hidden-range preview projection
/// (F4/AC5 edges E4/E6).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Tool _tool(String name, {Map<String, dynamic>? parameters}) => Tool(
  name: name,
  description: 'the $name tool',
  parameters:
      parameters ??
      const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
      },
);

void main() {
  group('prompt blobs (F1/AC1)', () {
    test('equal text dedups to one hash, different text changes it', () {
      final a = TrajectoryPromptBlob.of('You are a coding agent.');
      final b = TrajectoryPromptBlob.of('You are a coding agent.');
      final c = TrajectoryPromptBlob.of('You are a different agent.');
      expect(a.hash, b.hash);
      expect(a.hash, isNot(c.hash));
      expect(a.text, 'You are a coding agent.');
    });

    test('the blob table keeps one entry for two equal captures (AC1)', () {
      final blob = TrajectoryPromptBlob.of('same prompt');
      var table = const TrajectoryBlobTable();
      table = table.withPromptBlob(blob);
      table = table.withPromptBlob(TrajectoryPromptBlob.of('same prompt'));
      expect(table.systemPrompts, hasLength(1));
      // Two requests can point at the one stored version.
      expect(table.systemPrompts[blob.hash], same(blob));
    });

    test('giant prompts store whole — the F1 cap never applies (E2)', () {
      final giant = 'x' * (wireDumpMaxChars * 2);
      final blob = TrajectoryPromptBlob.of(giant);
      expect(blob.text.length, greaterThan(wireDumpMaxChars));
      expect(blob.hash, TrajectoryPromptBlob.of(giant).hash);
    });
  });

  group('prompt diff (AC2)', () {
    test('two versions differing by one section diff to exactly it', () {
      const before = 'line1\nline2\nsection: A\nline4\nline5';
      const after = 'line1\nline2\nsection: B\nline4\nline5';
      final lines = trajectoryPromptDiff(before, after);
      expect(lines.where((l) => l.kind == 'removed'), hasLength(1));
      expect(lines.where((l) => l.kind == 'added'), hasLength(1));
      expect(lines.firstWhere((l) => l.kind == 'removed').text, 'section: A');
      expect(lines.firstWhere((l) => l.kind == 'added').text, 'section: B');
    });

    test('collapsed flanks surface an ellipsis line', () {
      const head = 'a\na\na\na\na\na\na\na\na\na\n';
      final lines = trajectoryPromptDiff('${head}changed', '${head}edited');
      expect(lines.first.kind, 'ellipsis');
      expect(lines.where((l) => l.kind == 'ellipsis'), hasLength(1));
    });

    test('identical texts yield an empty diff', () {
      expect(trajectoryPromptDiff('same', 'same'), isEmpty);
    });

    test('a change with long flanks surfaces both ellipsis lines', () {
      const flank = 'a\na\na\na\na';
      const tail = 'z\nz\nz\nz\nz';
      final lines = trajectoryPromptDiff(
        '$flank\nchanged\n$tail',
        '$flank\nedited\n$tail',
      );
      expect(lines.first.kind, 'ellipsis');
      expect(lines.last.kind, 'ellipsis');
      expect(lines.where((l) => l.kind == 'ellipsis'), hasLength(2));
    });

    test('changes hugging the head render without a leading ellipsis', () {
      final lines = trajectoryPromptDiff(
        'head\nshared\nshared\nshared',
        'HEAD\nshared\nshared\nshared',
      );
      expect(lines.first.kind, 'removed');
      expect(
        lines,
        contains(
          isA<TrajectoryDiffLine>()
              .having((l) => l.kind, 'kind', 'added')
              .having((l) => l.text, 'text', 'HEAD'),
        ),
      );
      expect(lines.where((l) => l.kind == 'ellipsis'), isEmpty);
    });
  });

  group('tool manifests (F2/AC3)', () {
    test('the manifest carries descriptions and bounded schemas', () {
      final blob = TrajectoryToolManifestBlob.of([_tool('bash')]);
      expect(blob.tools, hasLength(1));
      expect(blob.tools.single.name, 'bash');
      expect(blob.tools.single.description, 'the bash tool');
      expect(blob.tools.single.schemaTruncated, isFalse);
      expect(blob.tools.single.schemaJson, contains('properties'));
    });

    test('an oversized schema truncates with the original size kept (E3)', () {
      final blob = TrajectoryToolManifestBlob.of([
        _tool('huge', parameters: {'type': 'object', 'x': 'y' * 9999}),
      ]);
      expect(blob.tools.single.schemaTruncated, isTrue);
      expect(blob.tools.single.schemaChars, greaterThan(toolSchemaMaxChars));
      expect(blob.tools.single.schemaJson.length, toolSchemaMaxChars);
    });

    test('the tool-set diff reports add/remove/modify lists (AC3)', () {
      final before = TrajectoryToolManifestBlob.of([
        _tool('bash'),
        _tool('read'),
      ]);
      final after = TrajectoryToolManifestBlob.of([
        _tool('bash'),
        _tool('write'),
      ]);
      final diff = trajectoryToolManifestDiff(before, after);
      expect(diff.added, ['write']);
      expect(diff.removed, ['read']);
      expect(diff.modified, isEmpty);
    });

    test('a schema-only change lands in modified, not removed', () {
      final before = TrajectoryToolManifestBlob.of([
        _tool('bash', parameters: const {'type': 'object'}),
      ]);
      final after = TrajectoryToolManifestBlob.of([
        _tool('bash', parameters: const {'type': 'object', 'x': {}}),
      ]);
      final diff = trajectoryToolManifestDiff(before, after);
      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.modified, ['bash']);
    });

    test('equal tool sets dedup to one manifest hash', () {
      final a = TrajectoryToolManifestBlob.of([_tool('bash'), _tool('read')]);
      final b = TrajectoryToolManifestBlob.of([_tool('bash'), _tool('read')]);
      expect(a.hash, b.hash);
    });
  });

  group('model-change capture (#440)', () {
    TrajectoryRequestDetail detail(String? promptHash, String? manifestHash) =>
        TrajectoryRequestDetail(
          messageCount: 1,
          systemPromptChars: 10,
          toolCount: 1,
          toolNames: const ['bash'],
          messages: const [],
          systemPromptHash: promptHash,
          toolManifestHash: manifestHash,
        );

    test('the first captured request opens the first version', () {
      final persister = TrajectoryBlobPersister();
      expect(persister.shouldAppendModelChange(detail('a', 'm')), isTrue);
    });

    test('an unchanged version never re-appends (AC2 dedupe)', () {
      final persister = TrajectoryBlobPersister();
      expect(persister.shouldAppendModelChange(detail('a', 'm')), isTrue);
      for (var i = 0; i < 10; i++) {
        expect(persister.shouldAppendModelChange(detail('a', 'm')), isFalse);
      }
    });

    test('either hash changing opens a new version', () {
      final persister = TrajectoryBlobPersister();
      expect(persister.shouldAppendModelChange(detail('a', 'm')), isTrue);
      expect(persister.shouldAppendModelChange(detail('b', 'm')), isTrue);
      expect(persister.shouldAppendModelChange(detail('b', 'm2')), isTrue);
      expect(persister.shouldAppendModelChange(detail('b', 'm2')), isFalse);
    });

    test('a version run that returns lands its row again (A→B→A)', () {
      final persister = TrajectoryBlobPersister();
      expect(persister.shouldAppendModelChange(detail('a', 'm')), isTrue);
      expect(persister.shouldAppendModelChange(detail('b', 'm')), isTrue);
      expect(persister.shouldAppendModelChange(detail('a', 'm')), isTrue);
    });

    test('a fully uncaptured request is not a version (E6)', () {
      final persister = TrajectoryBlobPersister();
      expect(persister.shouldAppendModelChange(detail(null, null)), isFalse);
      expect(persister.shouldAppendModelChange(detail('a', 'm')), isTrue);
      expect(persister.shouldAppendModelChange(detail(null, null)), isFalse);
    });

    test('reset drops the version state (new session)', () {
      final persister = TrajectoryBlobPersister();
      expect(persister.shouldAppendModelChange(detail('a', 'm')), isTrue);
      persister.reset();
      expect(persister.shouldAppendModelChange(detail('a', 'm')), isTrue);
    });
  });

  group('request message blocks (F3/AC4)', () {
    test('text blocks keep bounded full text with the original size', () {
      final blocks = trajectoryRequestBlocks([
        const TextContent(text: 'short'),
      ]);
      expect(blocks, hasLength(1));
      expect(blocks.single.type, 'text');
      expect(blocks.single.text, 'short');
      expect(blocks.single.truncated, isFalse);
    });

    test('an oversized block truncates but reports the full char count', () {
      final blocks = trajectoryRequestBlocks([
        TextContent(text: 'z' * (requestBlockChars + 50)),
      ]);
      expect(blocks.single.truncated, isTrue);
      expect(blocks.single.chars, requestBlockChars + 50);
      expect(blocks.single.text.length, requestBlockChars + 1);
    });

    test('an image block renders the WxH marker, never the bytes (AC4)', () {
      // 1x1 PNG.
      const png = [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
      ];
      final data = base64Encode(png);
      final blocks = trajectoryRequestBlocks([
        ImageContent(data: data, mimeType: 'image/png'),
      ]);
      expect(blocks.single.type, 'image');
      expect(blocks.single.imageMarker, '[image 1x1]');
      expect(blocks.single.text, isEmpty);
    });

    test('a short png header reports the unknown marker (E3)', () {
      final blocks = trajectoryRequestBlocks([
        ImageContent(data: base64Encode([0x89, 0x50]), mimeType: 'image/png'),
      ]);
      expect(blocks.single.imageMarker, '[image ?x?]');
    });

    test('jpeg SOF frames report dimensions, foreign payloads degrade', () {
      // SOF0 frame: FFC0, length 11, precision 8, height 32, width 16.
      const jpeg = [
        0xFF,
        0xD8,
        0xFF,
        0xC0,
        0x00,
        0x0B,
        0x08,
        0x00,
        0x20,
        0x00,
        0x10,
        0x01,
        0x01,
        0x11,
        0x00,
      ];
      expect(
        trajectoryRequestBlocks([
          ImageContent(data: base64Encode(jpeg), mimeType: 'image/jpeg'),
        ]).single.imageMarker,
        '[image 16x32]',
      );
      // A DHT marker (0xC4) is skipped, then SOF1 (0xC1) resolves:
      // height 5, width 3.
      const withDht = [
        0xFF, 0xD8, // SOI
        0xFF, 0xC4, 0x00, 0x05, 0x00, 0x00, 0x00, // DHT (skipped)
        0xFF, 0xC1, 0x00, 0x0B, 0x08, // SOF1
        0x00, 0x05, 0x00, 0x03, // height 5, width 3
        0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
      ];
      expect(
        trajectoryRequestBlocks([
          ImageContent(data: base64Encode(withDht), mimeType: 'image/jpg'),
        ]).single.imageMarker,
        '[image 3x5]',
      );
      // Truncated payload walking off the end, and a corrupt base64
      // body, both degrade to the unknown marker.
      expect(
        trajectoryRequestBlocks([
          ImageContent(
            data: base64Encode([0xFF, 0xD8]),
            mimeType: 'image/jpeg',
          ),
        ]).single.imageMarker,
        '[image ?x?]',
      );
      expect(
        trajectoryRequestBlocks([
          ImageContent(data: 'not!base64!', mimeType: 'image/png'),
        ]).single.imageMarker,
        '[image ?x?]',
      );
      // A webp payload is neither png nor jpeg.
      expect(
        trajectoryRequestBlocks([
          ImageContent(data: base64Encode(jpeg), mimeType: 'image/webp'),
        ]).single.imageMarker,
        '[image ?x?]',
      );
    });

    test('a toolCall block carries the call id and name', () {
      final blocks = trajectoryRequestBlocks([
        const ToolCall(id: 'call-1', name: 'bash', arguments: {'cmd': 'ls'}),
      ]);
      expect(blocks.single.type, 'toolCall');
      expect(blocks.single.callId, 'call-1');
      expect(blocks.single.toolName, 'bash');
      expect(blocks.single.text, contains('cmd'));
    });
  });

  group('wire dumps (F5/AC6)', () {
    final context = Context(
      systemPrompt: 'secret-in-prompt',
      messages: [
        UserMessage(
          timestamp: DateTime.utc(2026),
          content: [
            const TextContent(text: 'hello'),
            ImageContent(
              data: base64Encode(List.filled(64, 0x89)),
              mimeType: 'image/png',
            ),
          ],
        ),
      ],
      tools: [_tool('bash')],
    );

    test('payloads are provider-agnostic JSON with tools listed', () {
      final payload = trajectoryWireDumpPayload(context);
      expect(payload, contains('secret-in-prompt'));
      expect(payload, contains('"bash"'));
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      expect(decoded['systemPrompt'], 'secret-in-prompt');
      expect((decoded['messages'] as List), hasLength(1));
    });

    test('image payloads collapse to the omission marker (E5)', () {
      final payload = trajectoryWireDumpPayload(context);
      expect(payload, contains('[dump: image omitted]'));
      expect(payload, isNot(contains(base64Encode(List.filled(64, 0x89)))));
    });

    test('redaction runs through the host pipeline, secret absent (AC6)', () {
      final dump = trajectoryBuildWireDump(
        trajectoryWireDumpPayload(context),
        redact: (text) =>
            text.replaceAll('secret-in-prompt', '[REDACTED:api-key]'),
      );
      expect(dump.payload, isNot(contains('secret-in-prompt')));
      expect(dump.payload, contains('[REDACTED:api-key]'));
    });

    test('oversized payloads cut at the cap with the truncation marker', () {
      final (capped, truncated) = trajectoryCapWireDump(
        'a' * 300,
        maxChars: 100,
      );
      expect(truncated, isTrue);
      expect(capped.length, 100 + wireDumpTruncationMarker.length);
      expect(capped, endsWith(wireDumpTruncationMarker));
      final (kept, notTruncated) = trajectoryCapWireDump('short');
      expect(notTruncated, isFalse);
      expect(kept, 'short');
    });

    test('the built dump is content-addressed over the redacted payload', () {
      final a = trajectoryBuildWireDump('payload-a');
      final b = trajectoryBuildWireDump('payload-a');
      expect(a.hash, b.hash);
      expect(a.truncated, isFalse);
    });
  });

  group('hidden-range previews (F4/AC5)', () {
    test('resolved records preview bounded; missing ids stay honest (E6)', () {
      final user = MessageRecord(
        id: 'r1',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: UserMessage(content: 'x' * 400, timestamp: DateTime.utc(2026)),
      );
      final previews = projectHiddenRecordPreviews(
        recordIds: const ['r1', 'gone'],
        resolved: {'r1': user},
      );
      expect(previews, hasLength(2));
      expect(previews[0].type, 'MessageRecord');
      expect(previews[0].preview.length, hiddenRecordPreviewChars + 1);
      expect(previews[1].preview, '[hidden: not captured for this session]');
      expect(previews[1].type, 'missing');
    });

    test('rows are capped at hiddenRecordPreviewLimit (E4 open tail)', () {
      final previews = projectHiddenRecordPreviews(
        recordIds: [
          for (var i = 0; i < hiddenRecordPreviewLimit + 50; i++) 'r$i',
        ],
        resolved: const {},
      );
      expect(previews, hasLength(hiddenRecordPreviewLimit));
    });
  });
}
