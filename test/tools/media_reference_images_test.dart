// Copyright (c) 2026, the Flutter Agent Harness authors.
// gh-1844: reference-image inputs (path / URL / base64), the
// declared-or-discovered modality gate, and the OpenRouter models-probe
// capabilities parser.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show MemoryExecutionEnv;
import 'package:flutter_agent_harness/src/cli/paste_image.dart'
    show maxPasteImageBytes;
import 'package:flutter_agent_harness/src/tools/generate_image.dart'
    show MediaException;
import 'package:flutter_agent_harness/src/tools/media_reference_images.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('parseMediaImageInput', () {
    test('parses an https URL', () {
      final input = parseMediaImageInput(' https://example.com/a.png ');
      expect(input, isA<MediaImageUrl>());
      expect((input as MediaImageUrl).url, 'https://example.com/a.png');
    });

    test('parses a b64: payload', () {
      final input = parseMediaImageInput('b64:${base64Encode([1, 2])}');
      expect(input, isA<MediaImageBase64>());
      expect((input as MediaImageBase64).base64, base64Encode([1, 2]));
    });

    test('parses a data: URL', () {
      final input = parseMediaImageInput(
        'data:image/png;base64,${base64Encode([3])}',
      );
      expect(input, isA<MediaImageBase64>());
      expect((input as MediaImageBase64).base64, base64Encode([3]));
    });

    test('treats anything else as a sandbox path', () {
      final input = parseMediaImageInput('/tmp/ref.png');
      expect(input, isA<MediaImagePath>());
      expect((input as MediaImagePath).path, '/tmp/ref.png');
    });

    // gh-1844 CRAP gate: the bare-base64 auto-detect must be covered on
    // every branch of _looksLikeBase64 (all-valid, invalid character,
    // too short, path separator present).
    group('bare base64 auto-detect (CRAP coverage)', () {
      final bare64 = base64Encode(List<int>.filled(96, 7));

      test('a long base64-only string is base64', () {
        final input = parseMediaImageInput(bare64);
        expect(input, isA<MediaImageBase64>());
        expect((input as MediaImageBase64).base64, bare64);
      });

      test('the + padding character stays in the base64 alphabet', () {
        // No '/' — a path separator demotes to a path before the base64
        // sniff (separately covered below).
        final padded = '${'A' * 70}+==';
        final input = parseMediaImageInput(padded);
        expect(input, isA<MediaImageBase64>());
        expect((input as MediaImageBase64).base64, padded);
      });

      test('a non-base64 character demotes the entry to a path', () {
        // Interior '!' (trim only strips the ends) — not in the base64
        // alphabet, no path separator.
        final invalid = '${bare64.substring(0, bare64.length - 1)}!';
        final input = parseMediaImageInput(invalid);
        expect(input, isA<MediaImagePath>());
        expect((input as MediaImagePath).path, invalid);
      });

      test('a too-short base64-ish string is a path', () {
        final short = base64Encode([1, 2, 3, 4]); // well under 64 chars
        final input = parseMediaImageInput(short);
        expect(input, isA<MediaImagePath>());
        expect((input as MediaImagePath).path, short);
      });

      test('a path separator demotes the entry to a path', () {
        final withSlash = 'a$bare64/b';
        final input = parseMediaImageInput(withSlash);
        expect(input, isA<MediaImagePath>());
      });
    });

    test('rejects an empty entry', () {
      expect(() => parseMediaImageInput('   '), throwsA(isA<MediaException>()));
    });

    test('rejects a data URL without payload', () {
      expect(
        () => parseMediaImageInput('data:image/png;base64,'),
        throwsA(isA<MediaException>()),
      );
    });
  });

  group('resolveMediaImageInputs', () {
    test('resolves a sandbox path to sniffed inline bytes', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('refs/a.png', String.fromCharCodes([0x89, 0x50]));
      final resolved = await resolveMediaImageInputs(env, const [
        MediaImagePath('refs/a.png'),
      ]);
      expect(resolved, hasLength(1));
      expect(resolved[0].url, startsWith('data:image/'));
    });

    test('resolves multiple entries (2+) in order', () async {
      final env = MemoryExecutionEnv();
      final resolved = await resolveMediaImageInputs(env, const [
        MediaImageUrl('https://example.com/1.png'),
        MediaImageBase64('Qk0='),
      ]);
      expect(resolved, hasLength(2));
      expect(resolved[0].url, 'https://example.com/1.png');
      expect(resolved[1].url, startsWith('data:image/'));
    });

    test('a missing sandbox path fails with the path named', () async {
      final env = MemoryExecutionEnv();
      expect(
        resolveMediaImageInputs(env, const [MediaImagePath('nope.png')]),
        throwsA(
          isA<MediaException>().having(
            (e) => e.toString(),
            'message',
            contains('nope.png'),
          ),
        ),
      );
    });

    test('inline bytes above the paste cap are rejected', () async {
      final env = MemoryExecutionEnv();
      final big = Uint8List(maxPasteImageBytes + 1);
      expect(
        resolveMediaImageInputs(env, [MediaImageBase64(base64Encode(big))]),
        throwsA(
          isA<MediaException>().having(
            (e) => e.toString(),
            'message',
            contains('too large'),
          ),
        ),
      );
    });
  });

  group('parseOpenRouterCapabilities', () {
    test('finds the model architecture input/output modalities', () {
      final capabilities = parseOpenRouterCapabilities({
        'data': [
          {
            'id': 'other/model',
            'architecture': {
              'input_modalities': ['text'],
            },
          },
          {
            'id': 'google/gemini-3-pro-image-preview',
            'architecture': {
              'input_modalities': ['image', 'text'],
              'output_modalities': ['image'],
            },
          },
        ],
      }, 'google/gemini-3-pro-image-preview');
      expect(capabilities, isNotNull);
      expect(capabilities!.input, ['image', 'text']);
      expect(capabilities.output, ['image']);
    });

    test('returns null when the model is not listed', () {
      expect(
        parseOpenRouterCapabilities({
          'data': [
            {'id': 'other/model'},
          ],
        }, 'google/gemini-3-pro-image-preview'),
        isNull,
      );
    });
  });

  group('resolveInputModalities', () {
    const baseUrl = 'https://openrouter.ai/api/v1';

    test('declared modalities win without any probe', () async {
      final client = MockClient(
        (request) async => http.Response('unexpected call', 500),
      );
      final modalities = await resolveInputModalities(
        baseUrl: baseUrl,
        apiKey: 'k',
        modelId: 'm',
        declared: const ['image'],
        client: client,
      );
      expect(modalities, ['image']);
    });

    test(
      'discovers from the models endpoint when nothing is declared',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, '/api/v1/models');
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'm',
                  'architecture': {
                    'input_modalities': ['text'],
                  },
                },
              ],
            }),
            200,
          );
        });
        final modalities = await resolveInputModalities(
          baseUrl: baseUrl,
          apiKey: 'k',
          modelId: 'm',
          client: client,
        );
        expect(modalities, ['text']);
      },
    );

    test('probe failure degrades to unknown (null)', () async {
      final client = MockClient((request) async => http.Response('boom', 500));
      final modalities = await resolveInputModalities(
        baseUrl: baseUrl,
        apiKey: 'k',
        modelId: 'm',
        client: client,
      );
      expect(modalities, isNull);
    });
  });

  group('ensureImageInputSupported', () {
    test('image-capable endpoints pass', () {
      ensureImageInputSupported(
        slot: 'imageGeneration',
        modelId: 'm',
        inputModalities: const ['image', 'text'],
      );
    });

    test('unknown (null) capabilities pass through', () {
      ensureImageInputSupported(
        slot: 'imageGeneration',
        modelId: 'm',
        inputModalities: null,
      );
    });

    test('text-only endpoints reject with the declared modalities named', () {
      expect(
        () => ensureImageInputSupported(
          slot: 'videoGeneration',
          modelId: 'veo',
          inputModalities: const ['text'],
        ),
        throwsA(
          isA<MediaException>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('videoGeneration endpoint (model "veo")'),
              contains('does not accept image input'),
              contains('text'),
            ),
          ),
        ),
      );
    });
  });
}
