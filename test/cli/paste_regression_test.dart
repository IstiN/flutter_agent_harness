/// Pasted-image regression tests (issue #276, AC5):
///
/// - REG-redact: the redaction pipeline runs on pasted image METADATA and
///   never blocks the paste itself (payload untouched).
/// - REG-once: two pastes of the same image ride the provider request
///   exactly once (image registry #171 send-once invariant holds for the
///   composer-chip path — the message shape `_steerResolved` builds).
/// - The report/context leak guard lives in `compaction_report_test.dart`.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:test/test.dart';

final _chip = TuiImageAttachment(
  name: 'clipboard-1.png',
  mimeType: 'image/png',
  bytes: utf8.encode('png-bytes'),
);

UserMessage _steeredMessage(List<TuiImageAttachment> chips) => UserMessage(
  content: [
    TextContent(text: 'look at this'),
    for (final chip in chips)
      ImageContent(data: base64Encode(chip.bytes), mimeType: chip.mimeType),
  ],
  timestamp: DateTime.utc(2026),
);

int _occurrences(String haystack, String needle) {
  var count = 0;
  for (
    var i = haystack.indexOf(needle);
    i != -1;
    i = haystack.indexOf(needle, i + needle.length)
  ) {
    count++;
  }
  return count;
}

void main() {
  group('REG-redact: pipeline runs on pasted image metadata', () {
    test(
      'a secret in the mime label is masked, the payload rides intact',
      () async {
        final redactor = SecretRedactor()..register('k', 'supersecret9');
        final hooks = redactionHooks(redactor);
        // The paste-shaped message: text + image chip (mime carries the
        // secret, e.g. via a hostile pasteboard provider).
        final message = UserMessage(
          content: [
            TextContent(text: 'note supersecret9 in the body'),
            ImageContent(
              data: base64Encode(_chip.bytes),
              mimeType: 'image/supersecret9',
            ),
          ],
          timestamp: DateTime.utc(2026),
        );

        final transformed = await hooks.transformContext([message], null);
        expect(transformed, hasLength(1));
        final blocks =
            (transformed.first as UserMessage).content as List<ContentBlock>;
        final text = blocks.whereType<TextContent>().single;
        expect(text.text, 'note *** in the body');
        final image = blocks.whereType<ImageContent>().single;
        expect(image.mimeType, 'image/***');
        // The PAYLOAD is untouched — redaction never blocks the paste.
        expect(image.data, base64Encode(_chip.bytes));
      },
    );

    test('a clean paste passes through byte-identical', () async {
      final hooks = redactionHooks(
        SecretRedactor()..register('k', 'supersecret9'),
      );
      final message = UserMessage(
        content: [
          TextContent(text: 'look'),
          ImageContent(data: base64Encode(_chip.bytes), mimeType: 'image/png'),
        ],
        timestamp: DateTime.utc(2026),
      );
      final transformed = await hooks.transformContext([message], null);
      final blocks =
          (transformed.first as UserMessage).content as List<ContentBlock>;
      final image = blocks.whereType<ImageContent>().single;
      expect(image.data, base64Encode(_chip.bytes));
      expect(image.mimeType, 'image/png');
    });
  });

  group('REG-once: pasted chips keep the send-once invariant (#171)', () {
    test('the same bytes pasted twice ride one payload with refs', () {
      // Two submits of the same clipboard content: the first paste is
      // history by the time the second message is assembled — exactly the
      // block `_steerResolved` builds for each submit.
      final rewritten = rewriteHistoryImages([
        _steeredMessage([_chip]),
        _steeredMessage([_chip]),
      ]);

      final serialized = [
        for (final message in rewritten) message.toJson().toString(),
      ].join('\n');
      final payload = base64Encode(_chip.bytes);
      // One payload on the wire; the older paste became a text ref.
      expect(_occurrences(serialized, payload), 1);
      expect(_occurrences(serialized, '[Image 0]'), greaterThanOrEqualTo(2));
      expect(_occurrences(serialized, unavailableImageNote), 0);
    });
  });
}
