import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:image/image.dart';
import 'package:test/test.dart';

/// gh-1985 C2/C3 — `inspect_image` multi-image (array routing, compare
/// framing, programmatic stitch), `stitch: true` forcing, and the resize
/// control (`resize: "original"`). The vision endpoint is a capturing
/// fake; `InspectImageConfig.maxImagesPerCall` models the "single-image
/// only" model (1) vs the array-capable one (default).

Uint8List _makePng({int width = 2, int height = 2, int r = 255}) {
  final img = Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      img.getPixel(x, y)..r = r..g = (x * 7) % 256..b = (y * 11) % 256;
    }
  }
  return Uint8List.fromList(encodePng(img));
}

/// A deterministic NOISY png whose base64 exceeds [minChars] chars even
/// after re-encodes of moderate sizes — used for over-budget cases.
Uint8List _makeNoisyPng({int width = 600, int height = 600}) {
  final img = Image(width: width, height: height);
  var seed = 12345;
  int next() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed & 0xff;
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      img.getPixel(x, y)..r = next()..g = next()..b = next();
    }
  }
  return Uint8List.fromList(encodePng(img));
}

final class _CapturedCalls {
  final bodies = <Map<String, dynamic>>[];

  http.Client client(String content) {
    return http_testing.MockClient.streaming((request, bodyStream) async {
      bodies.add(
        jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>,
      );
      final payload = jsonEncode({
        'id': 'chatcmpl-test',
        'object': 'chat.completion.chunk',
        'created': 1234567890,
        'model': 'gpt-4o',
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant', 'content': content},
            'finish_reason': null,
          },
        ],
      });
      final done = jsonEncode({
        'id': 'chatcmpl-test',
        'object': 'chat.completion.chunk',
        'created': 1234567890,
        'model': 'gpt-4o',
        'choices': [
          {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
        ],
      });
      final sse = Stream.fromIterable(['data: $payload\n\n', 'data: $done\n\n']);
      return http.StreamedResponse(
        sse.transform(utf8.encoder),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
  }
}

List<dynamic> _userParts(Map<String, dynamic> body) {
  final messages = body['messages'] as List<dynamic>;
  final last = messages.last as Map<String, dynamic>;
  return last['content'] as List<dynamic>;
}

int _imagePartCount(Map<String, dynamic> body) => _userParts(body)
    .whereType<Map<String, dynamic>>()
    .where((part) => part['type'] == 'image_url')
    .length;

int _videoPartCount(Map<String, dynamic> body) => _userParts(body)
    .whereType<Map<String, dynamic>>()
    .where((part) => part['type'] == 'video_url')
    .length;

String _sentPrompt(Map<String, dynamic> body) => _userParts(body)
    .whereType<Map<String, dynamic>>()
    .where((part) => part['type'] == 'text')
    .map((part) => part['text'] as String)
    .join('\n');

String _resultText(dynamic result) => (result.content as List<ContentBlock>)
    .whereType<TextContent>()
    .map((b) => b.text)
    .join();

void main() {
  late MemoryExecutionEnv env;
  setUp(() {
    env = MemoryExecutionEnv();
    // Tests must not depend on ambient global config.
    // imageRegistryConfig is restored per-test where overridden.
  });

  Future<dynamic> runTool(
    InspectImageConfig config,
    Map<String, dynamic> args,
  ) async {
    final tool = inspectImageTool(env, config);
    return tool.execute(args, null, null);
  }

  group('single path form (AC5 REG)', () {
    test('stays byte-compatible: one call, one image part, raw pass-through '
        'of an in-limits image', () async {
      final bytes = _makePng();
      await env.writeBinaryFile('/work/a.png', bytes);
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('desc'),
      );
      final result = await runTool(config, {'path': '/work/a.png'});
      expect(calls.bodies, hasLength(1));
      expect(_imagePartCount(calls.bodies.single), 1);
      expect(_resultText(result), 'desc');
      // In-limits images ride their original bytes untouched.
      final parts = _userParts(calls.bodies.single)
          .whereType<Map<String, dynamic>>()
          .where((part) => part['type'] == 'image_url')
          .toList();
      final url = ((parts.single['image_url'] as Map)['url'] as String);
      expect(url, 'data:image/png;base64,${base64Encode(bytes)}');
    });

    test('mixed path+paths is rejected with a clear schema error', () async {
      await env.writeBinaryFile('/work/a.png', _makePng());
      await env.writeBinaryFile('/work/b.png', _makePng());
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: _CapturedCalls().client('x'),
      );
      expect(
        () => runTool(config, {
          'path': '/work/a.png',
          'paths': ['/work/a.png', '/work/b.png'],
        }),
        throwsA(
          isA<ToolValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('path'), contains('paths')),
          ),
        ),
      );
    });

    test('neither path nor paths is rejected with a clear schema error', () {
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: _CapturedCalls().client('x'),
      );
      expect(
        () => runTool(config, {'prompt': 'what?'}),
        throwsA(isA<ToolValidationException>()),
      );
    });

    test('an empty paths array is rejected with a clear schema error', () {
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: _CapturedCalls().client('x'),
      );
      expect(
        () => runTool(config, {
          'paths': <String>[],
        }),
        throwsA(isA<ToolValidationException>()),
      );
    });

    test('a non-image member fails with the path named (graceful, no call)',
        () async {
      await env.writeBinaryFile('/work/a.png', _makePng());
      await env.writeBinaryFile('/work/garbage.bin', Uint8List.fromList(
        List.generate(64, (i) => i),
      ));
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('x'),
      );
      await expectLater(
        runTool(config, {
          'paths': ['/work/a.png', '/work/garbage.bin'],
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('/work/garbage.bin'),
          ),
        ),
      );
      expect(calls.bodies, isEmpty, reason: 'no model call may fire');
    });
  });

  group('array routing (AC3)', () {
    test('paths [a, b] on an array-capable model → ONE call, two image parts',
        () async {
      await env.writeBinaryFile('/work/a.png', _makePng(r: 10));
      await env.writeBinaryFile('/work/b.png', _makePng(r: 200));
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('two images'),
      );
      final result = await runTool(config, {
        'paths': ['/work/a.png', '/work/b.png'],
      });
      expect(calls.bodies, hasLength(1), reason: 'ONE model call');
      expect(_imagePartCount(calls.bodies.single), 2);
      expect(_resultText(result), 'two images');
    });

    test('default prompt for several paths names each image in order',
        () async {
      await env.writeBinaryFile('/work/a.png', _makePng());
      await env.writeBinaryFile('/work/b.png', _makePng());
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('desc'),
      );
      await runTool(config, {
        'paths': ['/work/a.png', '/work/b.png'],
      });
      final prompt = _sentPrompt(calls.bodies.single);
      expect(prompt, contains('/work/a.png'));
      expect(prompt, contains('/work/b.png'));
    });

    test('a compare question rides the compare prompt shape', () async {
      await env.writeBinaryFile('/work/a.png', _makePng());
      await env.writeBinaryFile('/work/b.png', _makePng());
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('diff'),
      );
      await runTool(config, {
        'paths': ['/work/a.png', '/work/b.png'],
        'prompt': 'Which one has the red pixel?',
      });
      final prompt = _sentPrompt(calls.bodies.single);
      expect(prompt.toLowerCase(), contains('compare'));
      expect(prompt, contains('Which one has the red pixel?'));
      expect(prompt, contains('/work/a.png'));
      expect(prompt, contains('/work/b.png'));
    });

    test('single-image-only model + paths [a, b, c] → stitch composite '
        '(AC4): ONE call, one image part, tile labels in bytes, note maps '
        'A/B/C', () async {
      for (final name in ['a', 'b', 'c']) {
        await env.writeBinaryFile('/work/$name.png', _makePng(r: 40));
      }
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        maxImagesPerCall: 1,
        httpClient: calls.client('composite'),
      );
      final result = await runTool(config, {
        'paths': ['/work/a.png', '/work/b.png', '/work/c.png'],
      });
      expect(calls.bodies, hasLength(1), reason: 'ONE model call');
      expect(_imagePartCount(calls.bodies.single), 1);
      expect(_videoPartCount(calls.bodies.single), 0);

      // The emitted composite decodes and carries the tile labels: every
      // tile's glyph pixels are white at its expected origin.
      final parts = _userParts(calls.bodies.single)
          .whereType<Map<String, dynamic>>()
          .where((part) => part['type'] == 'image_url')
          .toList();
      final dataUrl = ((parts.single['image_url'] as Map)['url'] as String);
      final compositeBytes =
          base64Decode(dataUrl.split('base64,').last);
      final composite = decodeImage(compositeBytes)!;

      final letters = ['A', 'B', 'C'];
      for (var i = 0; i < letters.length; i++) {
        final origin = stitchTileOrigin(i, letters.length);
        final on = stitchGlyphPixels(letters[i]);
        for (final (dx, dy) in on) {
          // The glyph sits on a black plate [stitchPlatePadding] px inside
          // the tile corner (the placement [stitchTiles] guarantees).
          final pixel = composite.getPixel(
            origin.$1 + stitchPlatePadding + dx,
            origin.$2 + stitchPlatePadding + dy,
          );
          expect(
            pixel.r == 255 && pixel.g == 255 && pixel.b == 255,
            isTrue,
            reason:
                'tile ${letters[i]} label pixel ($dx,$dy) at origin $origin '
                'must be white (got $pixel)',
          );
        }
      }

      // The text note maps A/B/C → the source paths.
      final text = _resultText(result);
      expect(text, contains('A = /work/a.png'));
      expect(text, contains('B = /work/b.png'));
      expect(text, contains('C = /work/c.png'));
    });
  });

  group('stitch: true (AC5b)', () {
    test('forces the composite path on an array-capable model: ONE call, '
        'single image part, tile labels present', () async {
      await env.writeBinaryFile('/work/a.png', _makePng(r: 10));
      await env.writeBinaryFile('/work/b.png', _makePng(r: 200));
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('composite'),
      );
      final result = await runTool(config, {
        'paths': ['/work/a.png', '/work/b.png'],
        'stitch': true,
      });
      expect(calls.bodies, hasLength(1));
      expect(_imagePartCount(calls.bodies.single), 1);
      final text = _resultText(result);
      expect(text, contains('A = /work/a.png'));
      expect(text, contains('B = /work/b.png'));

      final parts = _userParts(calls.bodies.single)
          .whereType<Map<String, dynamic>>()
          .where((part) => part['type'] == 'image_url')
          .toList();
      final dataUrl = ((parts.single['image_url'] as Map)['url'] as String);
      final composite = decodeImage(base64Decode(dataUrl.split('base64,').last))!;
      final a = stitchGlyphPixels('A');
      final origin = stitchTileOrigin(0, 2);
      expect(
        composite
            .getPixel(
              origin.$1 + stitchPlatePadding + a.first.$1,
              origin.$2 + stitchPlatePadding + a.first.$2,
            )
            .r,
        255,
      );
    });

    test('stitch: true with a single path → clear schema hint (needs ≥2)',
        () async {
      await env.writeBinaryFile('/work/a.png', _makePng());
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: _CapturedCalls().client('x'),
      );
      await expectLater(
        runTool(config, {'path': '/work/a.png', 'stitch': true}),
        throwsA(
          isA<ToolValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('stitch'), contains('2')),
          ),
        ),
      );
    });

    test('default (no stitch param) keeps array routing per AC3', () async {
      await env.writeBinaryFile('/work/a.png', _makePng());
      await env.writeBinaryFile('/work/b.png', _makePng());
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('two'),
      );
      await runTool(config, {
        'paths': ['/work/a.png', '/work/b.png'],
      });
      expect(_imagePartCount(calls.bodies.single), 2);
    });

    test('9+ paths cap at 8 with a notice', () async {
      final paths = <String>[];
      for (var i = 0; i < 9; i++) {
        final p = '/work/img$i.png';
        await env.writeBinaryFile(p, _makePng());
        paths.add(p);
      }
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('many'),
      );
      final result = await runTool(config, {'paths': paths});
      expect(_imagePartCount(calls.bodies.single), 8);
      expect(_resultText(result), contains('8'));
    });
  });

  group('resize control (AC6)', () {
    test('default = settings ladder: an oversized image is downscaled '
        'before the call', () async {
      // A 2100px-wide image exceeds the 2000px inline dimension, so the
      // ladder must resize it before the model call.
      final bytes = _makeNoisyPng(width: 2100, height: 20);
      await env.writeBinaryFile('/work/wide.png', bytes);
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('desc'),
      );
      final result = await runTool(config, {'path': '/work/wide.png'});
      final parts = _userParts(calls.bodies.single)
          .whereType<Map<String, dynamic>>()
          .where((part) => part['type'] == 'image_url')
          .toList();
      final url = ((parts.single['image_url'] as Map)['url'] as String);
      final sent = base64Decode(url.split('base64,').last);
      expect(sent.length, isNot(bytes.length),
          reason: 'the ladder must re-encode an oversized image');
      final decoded = decodeImage(sent)!;
      expect(decoded.width, lessThanOrEqualTo(2000));
      final text = _resultText(result);
      expect(text, contains('desc'));
    });

    test('resize: "original" sends the original bytes when within budget',
        () async {
      final bytes = _makeNoisyPng(width: 2100, height: 20);
      await env.writeBinaryFile('/work/wide.png', bytes);
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('desc'),
      );
      await runTool(config, {'path': '/work/wide.png', 'resize': 'original'});
      final parts = _userParts(calls.bodies.single)
          .whereType<Map<String, dynamic>>()
          .where((part) => part['type'] == 'image_url')
          .toList();
      final url = ((parts.single['image_url'] as Map)['url'] as String);
      expect(
        url,
        'data:image/png;base64,${base64Encode(bytes)}',
        reason: 'resize=original keeps the original bytes verbatim '
            'when within the per-request budget',
      );
    });

    test('resize: "original" over budget → minimal downscale + note naming '
        'the applied size', () async {
      final bytes = _makeNoisyPng(width: 600, height: 600);
      await env.writeBinaryFile('/work/big.png', bytes);
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'k',
        httpClient: calls.client('desc'),
      );
      final previous = imageRegistryConfig;
      imageRegistryConfig = const ImageRegistryConfig(maxBytesPerRequest: 400);
      try {
        final result = await runTool(config, {
          'path': '/work/big.png',
          'resize': 'original',
        });
        final parts = _userParts(calls.bodies.single)
            .whereType<Map<String, dynamic>>()
            .where((part) => part['type'] == 'image_url')
            .toList();
        final url = ((parts.single['image_url'] as Map)['url'] as String);
        final sent = base64Decode(url.split('base64,').last);
        // Minimal downscale: still the original aspect ratio, and the
        // payload fits the budget now.
        final decoded = decodeImage(sent)!;
        expect(decoded.width / decoded.height, closeTo(1.0, 0.05));
        final base64LengthOfSent = ((sent.length + 2) ~/ 3) * 4;
        expect(base64LengthOfSent, lessThan(400));
        // The note names the applied size.
        final text = _resultText(result);
        expect(
          text,
          matches(RegExp(r'resized to \d+x\d+')),
          reason: 'the note must name the applied size, got: $text',
        );
      } finally {
        imageRegistryConfig = previous;
      }
    });

    test('resize param is documented in the tool description the agent sees',
        () {
      final config = InspectImageConfig(modelId: 'gpt-4o', apiKey: 'k');
      // The tool description must document both routing modes and the
      // resize option (AC5b/AC6 doc requirements).
      final description = inspectImageTool(
        MemoryExecutionEnv(),
        config,
      ).description;
      expect(description, contains('paths'));
      expect(description, contains('stitch'));
      expect(description, contains('original'));
    });
  });

  group('budgets (AC7)', () {
    test('multi-image call drops images over the per-request byte budget '
        'and fires the drop notice', () async {
      final dropped = <int>[];
      final previous = textOnlyImageDropNotice;
      textOnlyImageDropNotice = (count) => dropped.add(count);
      final previousConfig = imageRegistryConfig;
      imageRegistryConfig = const ImageRegistryConfig(maxBytesPerRequest: 400);
      try {
        for (var i = 0; i < 3; i++) {
          await env.writeBinaryFile('/work/n$i.png', _makeNoisyPng(width: 80));
        }
        final calls = _CapturedCalls();
        final config = InspectImageConfig(
          modelId: 'gpt-4o',
          apiKey: 'k',
          httpClient: calls.client('kept'),
        );
        final result = await runTool(config, {
          'paths': ['/work/n0.png', '/work/n1.png', '/work/n2.png'],
        });
        expect(_imagePartCount(calls.bodies.single), lessThan(3));
        expect(dropped, isNotEmpty);
        expect(_resultText(result), contains('omitted'));
      } finally {
        textOnlyImageDropNotice = previous;
        imageRegistryConfig = previousConfig;
      }
    });
  });

  group('stitch layout contract (deterministic)', () {
    test('≤3 tiles stack vertically; 4+ tiles grid 2-wide, last row padded',
        () {
      expect(stitchColumns(1), 1);
      expect(stitchColumns(3), 1);
      expect(stitchColumns(4), 2);
      expect(stitchColumns(8), 2);
      // 3 tiles: one column, three cells.
      expect(stitchCanvasSize(3), (stitchCell, stitchCell * 3));
      expect(stitchTileOrigin(1, 3), (0, stitchCell));
      expect(stitchTileOrigin(2, 3), (0, stitchCell * 2));
      // 5 tiles: 2-wide grid, 3 rows (last row padded by the canvas size).
      expect(stitchCanvasSize(5), (stitchCell * 2, stitchCell * 3));
      // Tile 4 (label E) sits FIRST in the padded last row: x = 4 % 2, so
      // the second cell of that row stays black.
      expect(stitchTileOrigin(4, 5), (0, stitchCell * 2));
      expect(stitchTileOrigin(3, 5), (stitchCell, stitchCell));
      // Heterogeneous sizes normalize per tile, keeping aspect.
      final wide = Image(width: 100, height: 40)..clear(ColorUint8.rgb(1, 2, 3));
      final tall = Image(width: 40, height: 100)..clear(ColorUint8.rgb(4, 5, 6));
      final composite = decodeImage(
        stitchTiles([wide, tall, wide, tall, wide]),
      )!;
      expect(
        composite.width,
        stitchCell * 2,
        reason: 'the composite canvas is exact — odd counts pad the last row',
      );
    });

    test('glyph pixels are deterministic for every tile label A–H', () {
      for (var i = 0; i < stitchTileLabels.length; i++) {
        final letter = stitchTileLabels[i];
        final pixels = stitchGlyphPixels(letter);
        expect(pixels, isNotEmpty);
        expect(
          pixels.every(
            (p) =>
                p.$1 >= 0 &&
                p.$1 < stitchGlyphWidth &&
                p.$2 >= 0 &&
                p.$2 < stitchGlyphHeight,
          ),
          isTrue,
        );
        // Distinct letters must differ (labels are distinguishable).
        for (var j = 0; j < i; j++) {
          expect(
            pixels,
            isNot(equals(stitchGlyphPixels(stitchTileLabels[j]))),
          );
        }
      }
    });
  });

  group('paths validation contract (gh-2007 review thread 5)', () {
    test('a non-string member is refused explicitly — nothing is silently '
        'dropped', () async {
      // `paths.whereType<String>()` used to filter junk members: a
      // [42, a, b] call inspected 2 images and never mentioned the 42.
      // The contract now matches the explicit-refusal style of the
      // path+paths and empty-array checks.
      await env.writeBinaryFile('/work/a.png', _makePng());
      await env.writeBinaryFile('/work/b.png', _makePng());
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: '[REDACTED:Sensitive-Value]',
        httpClient: calls.client('x'),
      );
      await expectLater(
        runTool(config, {
          'paths': [42, '/work/a.png', '/work/b.png'],
        }),
        throwsA(
          isA<ToolValidationException>().having(
            (e) => e.message,
            'message',
            allOf(contains('paths'), contains('string')),
          ),
        ),
      );
      expect(calls.bodies, isEmpty, reason: 'no model call may fire');
    });

    test('a single-element paths array still works (documented 1-8 range)',
        () async {
      // The schema documents 1-$inspectImageMaxPaths (a single-element
      // array rides the single-image branch); the text and the code agree.
      await env.writeBinaryFile('/work/a.png', _makePng());
      final calls = _CapturedCalls();
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: '[REDACTED:Sensitive-Value]',
        httpClient: calls.client('one'),
      );
      final result = await runTool(config, {
        'paths': ['/work/a.png'],
      });
      expect(calls.bodies, hasLength(1));
      expect(_imagePartCount(calls.bodies.single), 1);
      expect(_resultText(result), 'one');
    });

    test('the schema docs the 1-$inspectImageMaxPaths range the code '
        'enforces', () {
      final tool = inspectImageTool(
        MemoryExecutionEnv(),
        InspectImageConfig(
          modelId: 'gpt-4o',
          apiKey: '[REDACTED:Sensitive-Value]',
          httpClient: _CapturedCalls().client('x'),
        ),
      );
      final pathsSchema =
          (tool.parameters['properties'] as Map)['paths'] as Map;
      expect(
        pathsSchema['description'],
        contains('1-$inspectImageMaxPaths'),
        reason: 'schema text and validation must agree (thread 5)',
      );
    });
  });

  group('stitch × resize doc contract (gh-2007 review thread 6)', () {
    test('the tool description says resize does not apply to the stitched '
        'composite', () {
      final tool = inspectImageTool(
        MemoryExecutionEnv(),
        InspectImageConfig(
          modelId: 'gpt-4o',
          apiKey: '[REDACTED:Sensitive-Value]',
          httpClient: _CapturedCalls().client('x'),
        ),
      );
      expect(
        tool.description,
        contains('stitched'),
        reason: 'sanity',
      );
      expect(
        tool.description.toLowerCase(),
        contains('resize does not apply to the stitched composite'),
        reason:
            'agents must not reach for resize: "original" on a stitch call '
            'expecting byte fidelity — the composite is always re-encoded',
      );
    });
  });
}
