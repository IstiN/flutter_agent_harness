import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/redact/layer_asn1.dart';
import 'package:flutter_agent_harness/src/redact/layer_connection.dart';
import 'package:flutter_agent_harness/src/redact/layer_context.dart';
import 'package:flutter_agent_harness/src/redact/layer_entropy.dart';
import 'package:flutter_agent_harness/src/redact/layer_path.dart';
import 'package:flutter_agent_harness/src/redact/layer_pem.dart';
import 'package:flutter_agent_harness/src/redact/layer_pii.dart';
import 'package:flutter_agent_harness/src/redact/layer_registered.dart';
import 'package:flutter_agent_harness/src/redact/layer_vendor.dart';
import 'package:test/test.dart';

/// gh-1952 (I2 / AC2): every `[REDACTED:<kind>]` marker is ONE shell
/// token.
///
/// The incident: a masked define reached a child process as the literal
/// `[REDACTED:High Entropy String]` — with SPACES — and the shell split
/// it into 3 argv items (`[REDACTED:High`, `Entropy`, `String]`), which
/// the Flutter test loader tried to open as paths. Redaction is a mask
/// over what is SEEN, never a rewrite of what is EXECUTED: even when a
/// marker CAN leak into a shell string (an echoed mask, the #1408 bash
/// shape rewriter), it must stay one argv item. So the rendered marker
/// never contains whitespace, no matter what the layer label says.
void main() {
  /// Every layer label const, plus the dynamic labels layers synthesize
  /// (`PEM $header`, PII kinds, ...) — the full marker surface.
  const labels = <String>[
    asn1BlobLabel,
    connectionPasswordLabel,
    credentialLabel,
    credentialFileLabel,
    highEntropyLabel,
    registeredSecretLabel,
    sensitiveValueLabel,
    certificateDnLabel,
    githubTokenLabel,
    awsAccessKeyLabel,
    openAIKeyLabel,
    jwtLabel,
    gitLabTokenLabel,
    slackTokenLabel,
    googleApiKeyLabel,
    npmTokenLabel,
    'PEM PRIVATE KEY',
    'PEM ENCRYPTED PRIVATE KEY',
    'PEM OPENSSH PRIVATE KEY',
    'PEM CERTIFICATE',
    'PEM PUBLIC KEY',
    'PEM PGP PRIVATE KEY BLOCK',
    'Email',
    'Phone',
    'Credit Card',
    'SSN',
    'IBAN',
    'Certificate DN',
  ];

  group('redactionMarker renders single-token markers (gh-1952 I2)', () {
    test('every layer label renders whitespace-free', () {
      for (final label in labels) {
        expect(
          redactionMarker(label),
          isNot(contains(RegExp(r'\s'))),
          reason: 'label "$label" must render as one shell token',
        );
      }
    });

    test('whitespace runs inside a label become single hyphens', () {
      expect(redactionMarker('High Entropy String'),
          '[REDACTED:High-Entropy-String]');
      expect(redactionMarker('GitHub Token'), '[REDACTED:GitHub-Token]');
      expect(
        redactionMarker('Connection String Password'),
        '[REDACTED:Connection-String-Password]',
      );
      expect(redactionMarker('PEM RSA PRIVATE KEY'),
          '[REDACTED:PEM-RSA-PRIVATE-KEY]');
      expect(redactionMarker('Credit Card'), '[REDACTED:Credit-Card]');
    });

    test('a whitespace-free label is unchanged', () {
      expect(redactionMarker('JWT'), '[REDACTED:JWT]');
      expect(redactionMarker('credential'), '[REDACTED:credential]');
    });

    test('tabs and newlines are sanitized too', () {
      expect(
        redactionMarker('weird\tlabel\nkind'),
        '[REDACTED:weird-label-kind]',
      );
    });

    test('the pipeline emits whitespace-free markers for every layer', () {
      final pipeline = RedactionPipeline(registeredSecrets: const []);
      final texts = <String>[
        'key ghp_${'A' * 36} end', // vendor
        '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----', // pem
        'password=correcthorsebatterystaple', // context
        '/home/u/.env', // path
        'MII${'a' * 64}', // asn1
        'mysql://user:[REDACTED:Sensitive Value]@db.example.test/x', // connection
        'hash ${'qZ3mR7kW9pX2vB5nT8yC4jF6hD1sG0aL7eM3uQ9i'} end', // entropy
      ];
      for (final text in texts) {
        final out = pipeline.redact(text);
        final markers = RegExp(r'\[REDACTED:[^\]]*\]').allMatches(out);
        for (final marker in markers) {
          expect(
            marker.group(0),
            isNot(contains(RegExp(r'\s'))),
            reason: 'output of ${text.length > 30 ? '${text.substring(0, 30)}…' : text} '
                'must carry single-token markers, got ${marker.group(0)}',
          );
        }
      }
    });

    test('re-redaction stays idempotent on hyphenated markers', () {
      final pipeline = RedactionPipeline(registeredSecrets: const []);
      const src = 'key ghp_${'A' * 36} end';
      final once = pipeline.redact(src);
      final twice = pipeline.redact(once);
      expect(twice, once);
    });
  });
}
