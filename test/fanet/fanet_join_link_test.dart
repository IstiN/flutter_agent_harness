/// Tests for fa_network join-link parsing/building.
library;

import 'package:flutter_agent_harness/src/fanet/fanet_join_link.dart';
import 'package:test/test.dart';

void main() {
  group('FanetJoinLink.parse', () {
    test('parses a full link with password fragment', () {
      final link = FanetJoinLink.parse(
        'https://network.fa1.dev/join?network=net-123#pw=s3cret',
      );

      expect(link.restBase, Uri.parse('https://network.fa1.dev'));
      expect(link.networkId, 'net-123');
      expect(link.password, 's3cret');
    });

    test('tolerates a missing fragment (no password)', () {
      final link = FanetJoinLink.parse(
        'https://network.fa1.dev/join?network=net-123',
      );

      expect(link.restBase, Uri.parse('https://network.fa1.dev'));
      expect(link.networkId, 'net-123');
      expect(link.password, isNull);
    });

    test('tolerates an empty password fragment', () {
      final link = FanetJoinLink.parse(
        'https://network.fa1.dev/join?network=net-123#pw=',
      );

      expect(link.networkId, 'net-123');
      expect(link.password, isNull);
    });

    test('decodes percent-encoded network id and password', () {
      final link = FanetJoinLink.parse(
        'https://network.fa1.dev/join?network=net%2F1#pw=p%40ss%23word',
      );

      expect(link.networkId, 'net/1');
      expect(link.password, 'p@ss#word');
    });

    test('keeps a non-default port on the rest base', () {
      final link = FanetJoinLink.parse(
        'http://localhost:8080/join?network=net-1#pw=x',
      );

      expect(link.restBase, Uri.parse('http://localhost:8080'));
      expect(link.networkId, 'net-1');
    });

    test('rejects a non-join path', () {
      expect(
        () => FanetJoinLink.parse('https://network.fa1.dev/api?network=net-1'),
        throwsFormatException,
      );
    });

    test('rejects a link without a network query parameter', () {
      expect(
        () => FanetJoinLink.parse('https://network.fa1.dev/join#pw=x'),
        throwsFormatException,
      );
    });

    test('rejects an empty network query parameter', () {
      expect(
        () => FanetJoinLink.parse('https://network.fa1.dev/join?network='),
        throwsFormatException,
      );
    });

    test('rejects a non-http(s) scheme', () {
      expect(
        () => FanetJoinLink.parse('ftp://network.fa1.dev/join?network=net-1'),
        throwsFormatException,
      );
    });

    test('rejects a relative URL', () {
      expect(
        () => FanetJoinLink.parse('/join?network=net-1'),
        throwsA(anything),
      );
    });

    test('rejects an unexpected fragment shape', () {
      expect(
        () => FanetJoinLink.parse(
          'https://network.fa1.dev/join?network=net-1#token=x',
        ),
        throwsFormatException,
      );
    });

    test('rejects garbage input', () {
      expect(() => FanetJoinLink.parse(':::not a url'), throwsA(anything));
    });
  });

  group('FanetJoinLink.toUri', () {
    test('rebuilds a full link (round trip)', () {
      const source = 'https://network.fa1.dev/join?network=net-123#pw=s3cret';

      expect(FanetJoinLink.parse(source).toUri().toString(), source);
    });

    test('rebuilds a link without a password', () {
      const source = 'https://network.fa1.dev/join?network=net-123';

      expect(FanetJoinLink.parse(source).toUri().toString(), source);
    });

    test('encodes special characters in network id and password', () {
      final link = FanetJoinLink(
        restBase: 'https://network.fa1.dev',
        networkId: 'net/1',
        password: 'p@ss#word',
      );

      final built = link.toUri().toString();
      expect(built, contains('network=net%2F1'));
      expect(built, contains('#pw='));
      // `#` must be encoded (it would terminate the fragment otherwise).
      expect(built, contains('%23'));
      // The encoded form parses back to the same values.
      final reparsed = FanetJoinLink.parse(built);
      expect(reparsed.networkId, 'net/1');
      expect(reparsed.password, 'p@ss#word');
    });

    test('restBase can be given as a Uri', () {
      final link = FanetJoinLink(
        restBase: Uri.parse('http://localhost:9000'),
        networkId: 'net-1',
      );

      expect(link.restBase, Uri.parse('http://localhost:9000'));
      expect(
        link.toUri().toString(),
        'http://localhost:9000/join?network=net-1',
      );
    });
  });
}
