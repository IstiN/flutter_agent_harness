// CodeMie extension sign-in (web build inside the extension): the pure
// poll/parse core. The login happens in a NORMAL browser tab (no webview
// — IdPs send X-Frame-Options that forbid framing, and MV3 has no
// webview anyway); the extension-page fetch carries the cookie jar, so
// the flow just polls the models endpoint until the jar holds a session.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fa/services/codemie_extension_signin.dart';

void main() {
  group('codeMieModelIdsFromJson', () {
    test('parses the llm_models list, first non-empty id field wins', () {
      final models = codeMieModelIdsFromJson(
        jsonEncode([
          {'id': 'gpt-x'},
          {'base_name': 'claude-y', 'id': ''},
          {'deployment_name': 'gemini-z'},
        ]),
      );
      expect(models, ['gpt-x', 'claude-y', 'gemini-z']);
    });

    test('non-JSON body (a login HTML page answered 200) → null', () {
      expect(codeMieModelIdsFromJson('<html>sign in</html>'), isNull);
    });

    test('JSON non-list body → null; empty list → empty (manual entry)', () {
      expect(codeMieModelIdsFromJson('{"error":"no"}'), isNull);
      expect(codeMieModelIdsFromJson('[]'), isEmpty);
    });
  });

  group('pollCodeMieSignIn', () {
    test('first probe 200 → models, no login tab needed', () async {
      var probes = 0;
      var opened = 0;
      final models = await pollCodeMieSignIn(
        probe: () async {
          probes += 1;
          return (status: 200, body: '[{"id":"m1"}]');
        },
        openLoginPage: () => opened += 1,
        interval: Duration.zero,
      );
      expect(models, ['m1']);
      expect(probes, 1);
      expect(opened, 0);
    });

    test('401 opens the login tab once; a later 200 succeeds', () async {
      var probes = 0;
      var opened = 0;
      final models = await pollCodeMieSignIn(
        probe: () async {
          probes += 1;
          return probes == 1
              ? (status: 401, body: 'denied')
              : (status: 200, body: '[{"id":"m2"}]');
        },
        openLoginPage: () => opened += 1,
        interval: Duration.zero,
      );
      expect(models, ['m2']);
      expect(probes, 2);
      expect(opened, 1, reason: 'the tab opens once, not per probe');
    });

    test('200 with an HTML body keeps polling (not signed in yet)', () async {
      var probes = 0;
      final models = await pollCodeMieSignIn(
        probe: () async {
          probes += 1;
          return probes == 1
              ? (status: 200, body: '<html>login</html>')
              : (status: 200, body: '[{"id":"m3"}]');
        },
        openLoginPage: () {},
        interval: Duration.zero,
      );
      expect(models, ['m3']);
      expect(probes, 2);
    });

    test('deadline → null; cancel flag → null', () async {
      final timedOut = await pollCodeMieSignIn(
        probe: () async => (status: 401, body: 'denied'),
        openLoginPage: () {},
        timeout: const Duration(milliseconds: 30),
        interval: const Duration(milliseconds: 5),
      );
      expect(timedOut, isNull);

      var probes = 0;
      final gaveUp = await pollCodeMieSignIn(
        probe: () async {
          probes += 1;
          return (status: 401, body: 'denied');
        },
        openLoginPage: () {},
        interval: const Duration(milliseconds: 5),
        cancelled: () => probes >= 2,
      );
      expect(gaveUp, isNull);
      expect(probes, 2, reason: 'the cancel flag ends the polling loop');
    });

    test('a throwing probe (network hiccup) does not end the poll', () async {
      var probes = 0;
      final models = await pollCodeMieSignIn(
        probe: () async {
          probes += 1;
          if (probes == 1) throw StateError('offline');
          return (status: 200, body: '[{"id":"m4"}]');
        },
        openLoginPage: () {},
        interval: Duration.zero,
      );
      expect(models, ['m4']);
    });
  });
}
