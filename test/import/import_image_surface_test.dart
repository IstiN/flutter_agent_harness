import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/import/claude_adapter.dart';
import 'package:flutter_agent_harness/src/import/foreign_session.dart';
import 'package:test/test.dart';

/// UT tier — image-payload surface coverage (CRAP gate on
/// `foreign_session.dart` `_parseForeignImage`/`_inlineBase64` and
/// `claude_adapter.dart` `read`): every decode branch lands as either an
/// embedded [ForeignImage] or a counted placeholder, and the claude read
/// pass emits lifted tool results, on-path records, aux rides, and the
/// exact skip accounting for corrupt/sidechain/off-branch lines.
void main() {
  group('parseForeignContent image branches', () {
    var skips = 0;
    void onSkip() => skips++;

    setUp(() => skips = 0);

    ForeignImage singleImage(
      Map<String, dynamic> block, {
      ForeignImage? Function(String blobRef)? resolveBlob,
    }) => parseForeignContent(
      [block],
      onSkip,
      resolveBlob: resolveBlob,
    ).whereType<ForeignImage>().single;

    test('plain base64 embeds with the default png mime', () {
      final image = singleImage({'type': 'image', 'data': 'QUJD'});
      expect(image.base64Data, 'QUJD');
      expect(image.mimeType, 'image/png');
      expect(image.missingReason, isNull);
      expect(skips, 0);
    });

    test('data-URL header with the base64 flag is stripped', () {
      final image = singleImage({
        'type': 'image',
        'data': 'data:image/webp;base64,QUJD',
        'mimeType': 'image/webp',
      });
      expect(image.base64Data, 'QUJD');
      expect(image.mimeType, 'image/webp');
    });

    test('claude source shape supplies data and media_type', () {
      final image = singleImage({
        'type': 'image',
        'source': {
          'type': 'base64',
          'data': 'QUJD',
          'media_type': 'image/jpeg',
        },
      });
      expect(image.base64Data, 'QUJD');
      expect(image.mimeType, 'image/jpeg');
    });

    test('blob reference resolves through the resolver', () {
      final image = singleImage(
        {'type': 'image', 'data': 'blob:sha256:cafe'},
        resolveBlob: (ref) =>
            ForeignImage(base64Data: 'QUJD', mimeType: 'image/png'),
      );
      expect(image.base64Data, 'QUJD');
      expect(image.missingReason, isNull);
    });

    test('blob reference missing from the store is a counted placeholder', () {
      final image = singleImage({
        'type': 'image',
        'data': 'blob:sha256:dead',
      }, resolveBlob: (ref) => null);
      expect(image.base64Data, isNull);
      expect(image.missingReason, contains('blob not found'));
    });

    test('blob reference without any resolver is a placeholder too', () {
      final image = singleImage({'type': 'image', 'data': 'blob:sha256:beef'});
      expect(image.missingReason, contains('blob not found'));
    });

    test('undecodable payloads become placeholders, never throw', () {
      const blocks = [
        {
          'type': 'image',
          'data': 'data:image/svg+xml,<svg>',
        }, // header without base64 flag
        {'type': 'image', 'data': 'not base64!!'}, // charset violation
        {'type': 'image', 'data': ''}, // empty payload
        {'type': 'image'}, // no data, no source
        {
          'type': 'image',
          'source': 'not-a-map',
        }, // source present but not a map
        {'type': 'image', 'data': 42}, // non-string data
      ];
      final images = parseForeignContent(
        blocks,
        onSkip,
      ).whereType<ForeignImage>().toList();
      expect(images, hasLength(6));
      for (final image in images) {
        expect(image.base64Data, isNull);
        expect(image.missingReason, contains('undecodable'));
      }
      expect(skips, 0);
    });
  });

  group('ClaudeAdapter.read image and tree surface', () {
    late Directory home;
    late Directory project;
    late Directory faRoot;

    setUp(() {
      home = Directory.systemTemp.createTempSync('fa_import_img_home');
      project = Directory.systemTemp.createTempSync('fa_import_img_proj');
      faRoot = Directory.systemTemp.createTempSync('fa_import_img_fa');
    });

    tearDown(() {
      home.deleteSync(recursive: true);
      project.deleteSync(recursive: true);
      faRoot.deleteSync(recursive: true);
    });

    test('lifts tool results, parses on-path images, counts skips', () async {
      final bucket = Directory(
        '${home.path}/.claude/projects/${claudeProjectSlug(project.path)}',
      )..createSync(recursive: true);
      final cwd = project.path;
      File('${bucket.path}/claude-img.jsonl').writeAsStringSync('''
{"type":"session","version":3,"id":"claude-img","timestamp":"2026-10-10T10:00:00.000Z","cwd":"$cwd"}
{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":false,"sessionId":"claude-img","cwd":"$cwd","timestamp":"2026-10-10T10:01:00.000Z","message":{"role":"user","content":"plan the API"}}
{"type":"assistant","uuid":"a2","parentUuid":"u1","isSidechain":false,"sessionId":"claude-img","timestamp":"2026-10-10T10:02:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"fork dead end"}]}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","isSidechain":false,"sessionId":"claude-img","timestamp":"2026-10-10T10:02:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu-1","name":"write","input":{"path":"api.ts"}}],"model":"claude-x","stopReason":"toolUse"}}
{"type":"user","uuid":"u2","parentUuid":"a1","isSidechain":false,"sessionId":"claude-img","timestamp":"2026-10-10T10:03:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu-1","content":[{"type":"text","text":"done"}]},{"type":"image","source":{"type":"base64","data":"QUJD","media_type":"image/jpeg"}},{"type":"image","data":"data:image/png;base64,QUJD"},{"type":"image","data":"blob:sha256:cafe"},{"type":"image","data":"not base64!!"},{"type":"wat","x":1}]}}
{"type":"user","uuid":"s1","parentUuid":null,"isSidechain":true,"sessionId":"claude-img","timestamp":"2026-10-10T10:04:00.000Z","message":{"role":"user","content":"sidechain context"}}
this is not json
{"type":"last-prompt","prompt":"/model"}
''');
      final adapter = ClaudeAdapter();
      final summaries = await adapter.discover(
        fs: LocalExecutionEnv(cwd: project.path),
        cwd: project.path,
        homeDir: home.path,
        tempDir: Directory.systemTemp.path,
        limits: const ImportLimits(),
      );
      expect(summaries, hasLength(1));
      final parse = await adapter.read(
        fs: LocalExecutionEnv(cwd: project.path),
        summary: summaries.single,
        homeDir: home.path,
        limits: const ImportLimits(),
      );

      // Corrupt line + sidechain entry + off-branch fork a2 — each exactly
      // one counted skip; aux lines (session, last-prompt) are NOT skips.
      expect(parse.skippedRecords, 3);

      // Unmodeled types ride as inert custom data (GOAL C2).
      expect(
        parse.records.whereType<ForeignUnhandled>().map((r) => r.type).toSet(),
        {'session', 'last-prompt'},
      );

      final messages = parse.records.whereType<ForeignMessage>().toList();
      // u1 + a1 + u2's lifted tool_result + u2's parent message.
      expect(messages, hasLength(4));

      final toolResult = messages.firstWhere((m) => m.role == 'toolResult');
      expect(toolResult.toolCallId, 'tu-1');
      expect(toolResult.contents.single, isA<ForeignText>());

      final u2 = messages
          .where(
            (m) => m.role == 'user' && m.contents.any((c) => c is ForeignImage),
          )
          .single;
      final images = u2.contents.whereType<ForeignImage>().toList();
      expect(images, hasLength(4));
      expect(images[0].base64Data, 'QUJD');
      expect(images[0].mimeType, 'image/jpeg');
      expect(images[1].base64Data, 'QUJD');
      expect(images[1].mimeType, 'image/png');
      expect(images[2].missingReason, contains('blob not found'));
      expect(images[3].missingReason, contains('undecodable'));
      // The unmodeled block is counted (onSkip), never kept or dropped
      // silently.
      expect(u2.contents, hasLength(4));
      expect(parse.skippedBlocks, 1);

      final a1 = messages
          .where((m) => m.role == 'assistant' && m.model == 'claude-x')
          .single;
      // The lifted tool_result and its parent record share one source line.
      expect(toolResult.lineNumber, u2.lineNumber);
      expect(a1.lineNumber, isNot(toolResult.lineNumber));
    });
  });
}
